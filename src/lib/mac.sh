# Shared helpers for build.sh and apply.sh (sourced, Mac side).
log() { printf '\033[1;32m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
# python3 and the Swift answers without Xcode's Command Line Tools (src/lib/tools.sh).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tools.sh"
tools_path
source "$(dirname "${BASH_SOURCE[0]}")/version.sh"

# Progress for the control centre's jobs (OMACVM_PROGRESS=json, set by the
# Bridge): one JSON line per step, "step n of m". A command that runs another
# passes its count on (OMACVM_STEP_BASE steps done, OMACVM_STEP_OF in all).
OMA_STEP=${OMACVM_STEP_BASE:-0}; OMA_STEPS=${OMACVM_STEP_OF:-0}
step() {   # NAME TEXT
  OMA_STEP=$((OMA_STEP + 1)); (( OMA_STEP <= OMA_STEPS )) || OMA_STEPS=$OMA_STEP
  [[ ${OMACVM_PROGRESS:-} == json ]] || return 0
  local t=${2//\\/\\\\}; t=${t//\"/\\\"}
  printf '{"omacvm_progress": 1, "step": "%s", "n": %d, "of": %d, "text": "%s"}\n' "$1" "$OMA_STEP" "$OMA_STEPS" "$t"
}

# failed_part PART TEXT [SIDE]: what failed in a job (PART a feature, or
# empty; SIDE vm, the default, or mac), for the person and, as a JSON line,
# for the control centre.
failed_part() {
  local t
  t=$(printf '%s' "$2" | tr '\000-\037' ' ' | cut -c1-160)
  info "what failed: $t"
  [[ ${OMACVM_PROGRESS:-} == json ]] || return 0
  t=${t//\\/\\\\}; t=${t//\"/\\\"}
  printf '{"omacvm_failed": 1, "part": "%s", "text": "%s", "side": "%s"}\n' "$1" "$t" "${3:-vm}"
}

# mac_helper_feature HELPER: the feature a Mac helper is for (empty: none).
mac_helper_feature() {
  case $1 in
    "OmacVM Bridge") echo bridge ;;
    "OmacVM Gestures") echo gestures ;;
    Omanotch) echo omanotch ;;
  esac
}

# media_keys_state LINE: the Bridge's last "media keys: event tap|waiting|cannot"
# log line -> "ok|warn|fail<TAB>detail". The tap is created again whenever an
# OmacVM VM comes to the front or macOS invalidated it: that is how it works,
# not a failure. A failed re-creation keeps the old tap (works, so warn).
media_keys_state() {
  local m=${1#media keys: }
  case $m in
    "event tap installed"*|"event tap created again"*) printf 'ok\tevent tap installed\n' ;;
    *"keeping the old one"*) printf 'warn\t%s\n' "$m" ;;
    "") printf 'fail\tno event tap yet\n' ;;
    *) printf 'fail\t%s\n' "$m" ;;
  esac
}

# cli_for_bridge OMACVM: true when OMACVM (a checkout's omacvm, resolved) is
# the one the omacvm command runs: install.sh links it into one of these. So
# another clone or worktree that runs src/mac/install.sh never becomes what
# the Bridge runs (and moves on an update). No omacvm command at all (a clone
# run as ./omacvm): true. OMACVM_SET_CLI=1: true. OMACVM_CLI_LINKS: the links
# to look at, for tests.
cli_for_bridge() {
  local b links=0
  [[ ${OMACVM_SET_CLI:-} == 1 ]] && return 0
  for b in ${OMACVM_CLI_LINKS:-/opt/homebrew/bin/omacvm /usr/local/bin/omacvm $HOME/.local/bin/omacvm}; do
    [[ -e $b || -L $b ]] || continue
    links=1
    [[ $(realpath "$b" 2>/dev/null) == "$1" ]] && return 0
  done
  (( ! links ))
}

# cli_version OMACVM: the OmacVM version of that omacvm (its src/VERSION).
cli_version() { head -n1 "$(dirname "$(realpath "$1" 2>/dev/null || echo "$1")")/src/VERSION" 2>/dev/null; }

# cli_file_app OMACVM: OmacVM.app's copy of omacvm (OMACVM, inside the app)
# becomes what the Bridge runs, unless the file names a checkout that is still
# there (a CLI install keeps its own) and is not older than the app (#233: an
# old checkout ran the control centre's switches for a newer VM). So the
# app's setup, and each app start (app/app/Sources/OmacVM/ControlCLI.swift,
# the same rule), point it at the current app after an update or a move.
cli_file_app() {
  local f="$OMA_SUPPORT/cli" cur
  [[ $1 == /*/Contents/Resources/omacvm/omacvm && -f $1 ]] || return 0
  cur=$(head -n1 "$f" 2>/dev/null || true)
  [[ $cur == "$1" ]] && return 0
  if [[ -n $cur && -f $cur && $cur != */Contents/Resources/omacvm/omacvm ]] &&
     ! version_lt "$(cli_version "$cur")" "$(cli_version "$1")"; then return 0; fi
  mkdir -p "$OMA_SUPPORT"
  (umask 077; printf '%s\n' "$1" > "$f.new" && mv -f "$f.new" "$f")
}

PRLCTL=${PRLCTL:-/usr/local/bin/prlctl}   # tests: a stand-in
LEASES=/Library/Preferences/Parallels/parallels_dhcp_leases

# SSH into the guest as root with the OmacVM key. Each VM's host key is
# remembered the first time OmacVM sets the VM up (build, apply) and checked on
# every later connection: OMA_PIN is that VM's file (vm_pin, vm.sh), and
# OMA_PIN_NEW=1 lets a connection record the key when there is none yet. A VM
# without a remembered key (and OMA_PIN_NEW unset) is reached as before.
# IP:PORT for OmacVM.app's VMs (127.0.0.1 and the VM's SSH port).
# OMACVM_TEST_IDENTITY=1: the test identity ("OmacVM Test", app/scripts/build-app.sh
# --test-identity, whose Bridge runs omacvm with it): its own folders, never the
# installed helpers' token, keys or pins.
if [[ ${OMACVM_TEST_IDENTITY:-} == 1 ]]; then
  OMA_SUPPORT="$HOME/Library/Application Support/omacvm-test"
  OMA_BRIDGE_SUPPORT="$HOME/Library/Application Support/omacvm-test-bridge"
else
  OMA_SUPPORT="$HOME/Library/Application Support/omacvm"
  OMA_BRIDGE_SUPPORT="$HOME/Library/Application Support/omacvm-bridge"
fi
OMA_PINS="$OMA_SUPPORT/known_hosts"
gssh() {
  local ip=$1 port=22; shift
  [[ $ip == *:* ]] && { port=${ip##*:}; ip=${ip%:*}; }
  local hk=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
  if [[ -n ${OMA_PIN:-} ]] && [[ -s $OMA_PIN || ${OMA_PIN_NEW:-} == 1 ]]; then
    [[ -s $OMA_PIN ]] || { mkdir -p "$(dirname "$OMA_PIN")" && chmod 700 "$(dirname "$OMA_PIN")"; }
    hk=(-o "StrictHostKeyChecking=$([[ -s $OMA_PIN ]] && echo yes || echo accept-new)"
        -o "UserKnownHostsFile=\"$OMA_PIN\"" -o HostKeyAlias=omacvm-vm -o CheckHostIP=no)
  fi
  ssh -i "${OMA_KEY:-$HOME/.ssh/omacvm}" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=30 \
    "${hk[@]}" -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR -p "$port" "root@$ip" "$@"
}

# ssh_failure_why IP FILE: why SSH did not get in, from ssh's own messages in
# FILE (vm_probe with OMA_PROBE_ERR), one line; "hostkey" first when the VM
# answered with another host key than the one remembered. No second
# connection: every unauthenticated one (ssh-keyscan opens several) counts
# against the Mac in sshd's PerSourcePenalties (OpenSSH 9.8+), and enough of
# them turn the Mac away for up to 10 minutes; all of the Mac's connections
# come from one address (QEMU's user network: 10.0.2.2).
ssh_failure_why() {
  local ip=$1 e
  e=$(tr -d '\r' < "$2" 2>/dev/null | grep -v '^ *$' | grep -viE '^(@|It is also possible|Someone could be|Please contact|Add correct|Offending|Host key for|[A-Z]+ host key for)' | head -3 | tr '\n' ' ' | sed 's/ *$//')
  if grep -qE 'Host key verification failed|IDENTIFICATION HAS CHANGED' "$2" 2>/dev/null; then
    echo "hostkey $ip answers with another SSH host key"
  elif grep -q 'Permission denied' "$2" 2>/dev/null; then echo "OmacVM's SSH key did not get in at $ip"
  elif grep -q 'Connection refused' "$2" 2>/dev/null; then echo "nothing takes SSH at $ip (the VM is starting, or its SSH stopped)"
  elif grep -qiE 'timed out|Operation timed out' "$2" 2>/dev/null; then echo "SSH at $ip did not answer (the VM is busy, or its network is down)"
  elif grep -qE 'Connection (reset|closed)|kex_exchange_identification|Broken pipe' "$2" 2>/dev/null; then
    echo "SSH at $ip closed the connection (the VM is busy or starting, or its SSH turns the Mac away for a while after many tries)"
  elif [[ -n $e ]]; then echo "SSH to $ip did not get in: $(printf '%s' "$e" | tr -d '\000-\037' | cut -c1-160)"
  else
    # Nothing said: the VM's sshd closed the connection before a word (as it
    # does while PerSourcePenalties turns the Mac away; seen 2026-10-07).
    echo "SSH at $ip closed the connection (the VM is busy or starting, or its SSH turns the Mac away for a while after many tries)"
  fi
}

# hostkey_changed IP [SECONDS]: the VM answers, with other host keys than the one
# remembered for it.
hostkey_changed() {
  [[ -n ${OMA_PIN:-} && -s ${OMA_PIN:-} ]] || return 1
  local _h t k seen=0 ip=$1 port=22
  [[ $ip == *:* ]] && { port=${ip##*:}; ip=${ip%:*}; }   # OmacVM.app: 127.0.0.1:PORT
  while read -r _h t k; do
    [[ -n $k ]] || continue
    # Only a key of a type remembered tells: a scan cut short by a busy VM
    # may bring only the others.
    grep -qF " $t " "$OMA_PIN" || continue
    seen=1
    grep -qF " $t $k" "$OMA_PIN" && return 1
  done < <(ssh-keyscan -T "${2:-5}" -p "$port" "$ip" 2>/dev/null)
  (( seen ))
}

hostkey_error() {   # the VM's name (VM) and how apply names it (OMA_PIN_ARGS) come from vm_pin
  printf '\033[1;31merror:\033[0m %s answers with another SSH host key than the one OmacVM remembered for it.\n' "${VM:-the VM}" >&2
  local how="omacvm apply ${OMA_PIN_ARGS:-} --reset-host-key"
  [[ -n ${OMA_RESET_HINT:-} ]] && how=$OMA_RESET_HINT   # OmacVM.app's apply-vm.sh
  printf 'If you rebuilt or reinstalled it, forget the old key:\n\n  %s\n\nIf not, something else may answer at its address: do not go on.\n' \
    "$how" >&2
}

# The Bridge's token (the Bridge makes it on its first start). The VMs' gestures
# daemons say it too, so it is made here when Gestures comes without the Bridge.
BRIDGE_TOKEN="$OMA_BRIDGE_SUPPORT/token"
bridge_token_ensure() {
  [[ -f $BRIDGE_TOKEN && $(tr -d '[:space:]' < "$BRIDGE_TOKEN" | wc -c) -ge 32 ]] && return 0
  mkdir -p "$(dirname "$BRIDGE_TOKEN")" && chmod 700 "$(dirname "$BRIDGE_TOKEN")"
  (umask 077; openssl rand -hex 32 > "$BRIDGE_TOKEN")
}

# The control centre's key for one VM (TYPE NAME): the Bridge acts for a VM
# only when its request carries this key, so a VM that takes another VM's
# address cannot act for it (src/bridge/mac/control.swift reads it). Made at
# the VM's first apply, again with "new" (apply --reset-host-key: a rebuilt VM).
VM_KEYS="$OMA_SUPPORT/vm-keys"
vm_key_file() { printf '%s/%s' "$VM_KEYS" "$(printf '%s/%s' "$1" "$2" | shasum -a 256 | cut -c1-32)"; }
vm_key_ensure() {   # TYPE NAME [new] -> the key's file
  local f; f=$(vm_key_file "$1" "$2")
  if [[ ${3:-} == new || ! -s $f ]]; then
    mkdir -p "$VM_KEYS" && chmod 700 "$VM_KEYS"
    (umask 077; openssl rand -hex 32 > "$f.tmp") && mv -f "$f.tmp" "$f"
  fi
  echo "$f"
}

# Touch ID's key for one VM (ADR 0041), beside its control key: the Bridge
# shows a Touch ID dialog only for a VM whose request carries it. In the VM
# it is root's alone (/etc/omacvm/touchid-key). Gone when the feature is off.
touchid_key_ensure() {   # TYPE NAME [new] -> the key's file
  local f; f=$(vm_key_file "$1" "$2").touchid
  if [[ ${3:-} == new || ! -s $f ]]; then
    mkdir -p "$VM_KEYS" && chmod 700 "$VM_KEYS"
    (umask 077; openssl rand -hex 32 > "$f.tmp") && mv -f "$f.tmp" "$f"
  fi
  echo "$f"
}

# Omanotch on this Mac serves OmacVM.app's VMs (on 127.0.0.1) only from the
# version that knows the app's QEMU: 0 it does, 1 too old, 2 not installed.
omanotch_serves_app() {
  local b=$HOME/Applications/Omanotch.app/Contents/MacOS
  [[ -d $b ]] || return 2
  grep -aqF /Contents/Resources/runtime/bin/OmacVM "$b"/* 2>/dev/null || return 1
}
# ... and on the app's fast network (192.168.77.1): 0 it does, 1 too old, 2 not installed.
omanotch_serves_fast_network() {
  local b=$HOME/Applications/Omanotch.app/Contents/MacOS
  [[ -d $b ]] || return 2
  grep -aqF "on OmacVM.app's fast network" "$b"/* 2>/dev/null || return 1
}

wait_ssh() {   # <ip> [seconds]: 3 when the VM's host key changed
  # By the clock: each try can take seconds of its own. Another host key is
  # told by ssh itself (ssh_failure_why), never by a key scan per try: a VM
  # still booting would otherwise count a scan every 5 s against the Mac and
  # turn it away for minutes once it is up (PerSourcePenalties).
  local end=$((SECONDS + ${2:-600})) err
  err=$(mktemp -t omacvm-ssh)
  while :; do
    gssh "$1" true 2>"$err" && { rm -f "$err"; return 0; }
    [[ $(ssh_failure_why "$1" "$err") == "hostkey "* ]] && { rm -f "$err"; hostkey_error; return 3; }
    (( SECONDS < end )) || break
    sleep 5
  done
  rm -f "$err"
  die "no SSH on $1 after ${2:-600} s"
}

vm_bundle() {   # <vm name> -> path of its .pvm
  local p
  p=$("$PRLCTL" list -a -i "$1" 2>/dev/null | sed -n 's/^Home: \(.*\)\/$/\1/p; s/^Home: \(.*\)$/\1/p' | head -1)
  [[ -n $p ]] && echo "$p" || echo "$HOME/Parallels/$1.pvm"
}

vm_mac() {   # <pvm> -> guest MAC (lower case, no separators)
  python3 - "$1/config.pvs" <<'PY'
import sys, xml.etree.ElementTree as ET
print(ET.parse(sys.argv[1]).getroot().findtext("Hardware/NetworkAdapter/MAC", "").lower())
PY
}

vm_ip() {   # <pvm> [seconds] -> the IP Parallels' DHCP gave the guest's MAC
  local mac i ip
  mac=$(vm_mac "$1")
  [[ -n $mac ]] || return 1
  for ((i = 0; i < ${2:-1}; i += 3)); do
    ip=$(grep -i "$mac" "$LEASES" 2>/dev/null | sed -n 's/^\(10\.211\.55\.[0-9]*\)=.*/\1/p' | tail -1)
    [[ -n $ip ]] && { echo "$ip"; return 0; }
    sleep 3
  done
  return 1
}

vm_state() {   # <vm name> -> running|stopped|...
  "$PRLCTL" list -a -o status,name 2>/dev/null | awk -v n="$1" 'NR > 1 { s = $1; $1 = ""; sub(/^ /, ""); if ($0 == n) print s }'
}

wait_stopped() {   # <vm name>
  local i
  # Parallels can take minutes to close a VM's sound devices when macOS's
  # audio service is slow to answer it (seen: 7 minutes for the microphone).
  for ((i = 0; i < 600; i += 3)); do [[ $(vm_state "$1") == stopped ]] && return 0; sleep 3; done
  die "VM '$1' did not stop"
}

# Parallels' "Send macOS system shortcuts" (Settings > Shortcuts > macOS System
# Shortcuts) has no CLI, plist key or VM setting. With "Always", Parallels
# writes ~/Library/Preferences/Parallels/sendtovmkeys.dat: a count, then one
# 9-byte entry per macOS shortcut with a 4-byte flag of 1. Undocumented, so a
# best guess, only used to decide whether to remind the user.
parallels_sends_shortcuts() {
  python3 - "$HOME/Library/Preferences/Parallels/sendtovmkeys.dat" 2>/dev/null <<'EOF'
import struct, sys
b = open(sys.argv[1], "rb").read()
n = struct.unpack(">I", b[:4])[0]
entries = [b[4 + 9 * i:13 + 9 * i] for i in range(n)]
sys.exit(0 if n and len(b) == 4 + 9 * n and all(e[1:5] == b"\0\0\0\1" for e in entries) else 1)
EOF
}

# Parallels' "Linux" keyboard profile emptied by mac/parallels-shortcuts.sh?
parallels_profile_emptied() {
  [[ $(xxd -p "$HOME/Library/Preferences/Parallels/Linux.dat" 2>/dev/null | tr -d '\n') == \
     00030231000000010000000a004c0069006e00750078000000000000000000000000 ]]
}

# Ask for that one setting with mac/parallels-system-shortcuts.sh (alerts, in
# the background: the calling script goes on and may end first).
parallels_shortcuts_alert() {
  nohup "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/mac/parallels-system-shortcuts.sh" >/dev/null 2>&1 &
}

vm_start() {   # <vm name> <pvm>: opening the bundle in Parallels Desktop starts it
  local i
  # Full screen on every Mac display (VMs from before 2.2 lack it); Parallels
  # reads config.pvs when the VM starts.
  python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/vm/pvs.py" "$2/config.pvs" displays 2>/dev/null || true
  # OMACVM_HEADLESS=1 (image builds, tests): no window (Pro and trial editions).
  if [[ ${OMACVM_HEADLESS:-} == 1 ]]; then
    "$PRLCTL" set "$1" --startup-view headless >/dev/null 2>&1 && "$PRLCTL" start "$1" >/dev/null 2>&1 && return 0
  fi
  open -a "Parallels Desktop" "$2"
  for ((i = 0; i < 60; i += 3)); do [[ $(vm_state "$1") == running ]] && return 0; sleep 3; done
  "$PRLCTL" start "$1" >/dev/null 2>&1 && return 0      # Pro/Business editions
  log "start the VM '$1' in Parallels Desktop (click the play button), waiting..."
  for ((i = 0; i < 600; i += 3)); do [[ $(vm_state "$1") == running ]] && return 0; sleep 3; done
  die "VM '$1' did not start"
}

# Parallels Tools from this Mac's Parallels Desktop into the VM at IP.
parallels_tools_install() {
  local iso="/Applications/Parallels Desktop.app/Contents/Resources/Tools/prl-tools-lin-arm.iso"
  [[ -f $iso ]] || die "Parallels Tools not found: $iso"
  gssh "$1" "cat > /root/prl-tools-lin-arm.iso" < "$iso"
  gssh "$1" "set -e; mkdir -p /mnt/tools; mount -o loop,ro /root/prl-tools-lin-arm.iso /mnt/tools
    /mnt/tools/installer/install-cli.sh --install >/dev/null 2>&1 || /mnt/tools/installer/install-cli.sh --install
    umount /mnt/tools; rm -f /root/prl-tools-lin-arm.iso"
}

# ---- UTM ----
UTMCTL=${UTMCTL:-/Applications/UTM.app/Contents/MacOS/utmctl}

# UTM keeps its VMs and settings in its sandbox container. macOS 14 and later
# asks before another app reads there ("access data from other apps"), and
# the reading process waits until someone answers: a Bridge job, an agent or a
# script hangs, and the person gets a prompt nobody asked for. So OmacVM
# - leaves UTM alone unless UTM is used with OmacVM on this Mac (utm_used),
# - reads the container only when someone asked for UTM, and for at most
#   2 seconds (utm_data),
# - keeps the UTM VM names it saw in its own folder (utm_seen), so a list
#   still has them when UTM's data cannot be read.
UTM_DATA=$HOME/Library/Containers/com.utmapp.UTM/Data
UTM_SEEN="$OMA_SUPPORT/utm-vms"
UTM_UNREADABLE="UTM data not readable"
UTM_UNREADABLE_HINT="$UTM_UNREADABLE: run omacvm in a terminal app on the Mac (macOS asks once whether it may read UTM's data), or open UTM"
# A person at a terminal runs this omacvm (stdin as it started; utm_data's own
# stdin may be a heredoc).
UTM_TTY=0; [[ -t 0 ]] && UTM_TTY=1

# utm_used: asked for (OMACVM_UTM=1, a command on a UTM VM), or OmacVM saw or
# set up a UTM VM here (its own files only).
utm_used() {
  [[ ${OMACVM_UTM:-} == 1 || ${TYPE:-} == utm || -s $UTM_SEEN ]] && return 0
  compgen -G "$OMA_PINS/utm-*" >/dev/null
}

# utm_data CMD...: run CMD, which reads UTM's container, only when someone
# asked for UTM (a person at a terminal, a command on a UTM VM, OMACVM_UTM=1);
# killed after UTM_DATA_WAIT seconds (2). Fails at once otherwise: never from
# the Bridge listing VMs or from a script.
utm_data() {
  utm_used && [[ ${OMACVM_UTM:-} == 1 || ${TYPE:-} == utm || $UTM_TTY == 1 ]] || return 1
  perl -e 'my $t = shift; my $p = fork // exit 127; if (!$p) { exec { $ARGV[0] } @ARGV or exit 127 }
    $SIG{ALRM} = sub { kill "KILL", $p; exit 142 }; alarm $t; waitpid($p, 0);
    exit($? & 127 ? 128 + ($? & 127) : $? >> 8)' "${UTM_DATA_WAIT:-2}" "$@"
}

# utm_seen: the UTM VM names OmacVM saw, one per line. utm_seen_set: the
# names on stdin are the list now.
utm_seen() { cat "$UTM_SEEN" 2>/dev/null; return 0; }
utm_seen_set() {
  mkdir -p "$OMA_SUPPORT" && sed '/^$/d' > "$UTM_SEEN.$$" && mv -f "$UTM_SEEN.$$" "$UTM_SEEN"
}

vm_type() {   # <vm name> -> parallels | utm; a name in both: the one that is running
  local p="" u=""
  [[ -x $PRLCTL ]] && "$PRLCTL" list -a -o name 2>/dev/null | sed 1d | grep -qxF "$1" && p=1
  [[ -x $UTMCTL ]] && "$UTMCTL" list 2>/dev/null | awk 'NR > 1 { $1 = ""; $2 = ""; sub(/^  /, ""); print }' | grep -qxF "$1" && u=1
  if [[ -n $p && -n $u ]]; then
    [[ $(utm_state "$1") == started ]] && echo utm || echo parallels
  elif [[ -n $p ]]; then echo parallels
  elif [[ -n $u ]]; then echo utm
  else return 1; fi
}

utm_state() {   # <vm name> -> started|stopped|...
  "$UTMCTL" status "$1" 2>/dev/null | tr -d '[:space:]'; echo
}

# lease_ip MAC: the newest address macOS's DHCP server (bootpd: vmnet's shared
# network) gave that MAC (aa:bb:..; the lease file drops leading zeros).
lease_ip() {
  local m
  m=$(tr 'A-F' 'a-f' <<<"$1" | sed 's/:0/:/g; s/^0//')
  [[ -n $m ]] || return 1
  awk -v m="1,$m" '/ip_address=/ { split($0, a, "="); ip = a[2] } /hw_address=/ { split($0, b, "="); if (b[2] == m) print ip }' \
    /var/db/dhcpd_leases 2>/dev/null | tail -1
}

utm_ip() {   # <vm name> [seconds]: the guest's address on UTM's shared network
  local ip mac="" end=$((SECONDS + ${2:-1})) ask=1
  # utmctl and AppleScript wait while macOS asks whether this terminal may
  # control UTM (and fail over SSH): 15 seconds each, the MAC from the VM's
  # own settings first, and no more utmctl after one went unanswered.
  declare -F vm_hw_mac >/dev/null && mac=$(vm_hw_mac "$1" utm | sed 's/../&:/g; s/:$//') || true
  while :; do
    # the QEMU guest agent knows; without it, UTM's DHCP server (bootpd) does
    if (( ask )); then
      ip=$(perl -e 'alarm shift; exec @ARGV' 15 "$UTMCTL" ip-address "$1" 2>/dev/null) || { (( $? <= 128 )) || ask=0; }
      ip=$(grep -m1 -E '^192\.168\.[0-9]+\.[0-9]+$' <<<"$ip") && { echo "$ip"; return 0; }
    fi
    # the name goes in as an argument, never into the script's source
    [[ -n $mac ]] || mac=$(osascript -e 'on run argv' -e 'with timeout of 15 seconds' -e 'tell application "UTM"' \
            -e 'copy (configuration of virtual machine named (item 1 of argv)) to c' \
            -e 'get address of item 1 of (network interfaces of c)' -e 'end tell' -e 'end timeout' -e 'end run' "$1" 2>/dev/null) || true
    if [[ -n $mac ]]; then
      ip=$(lease_ip "$mac")
      [[ -n $ip ]] && { echo "$ip"; return 0; }
    fi
    (( SECONDS < end )) || return 1
    sleep 3
  done
}

utm_start() {   # <vm name>: UTM must run in the foreground (open -g makes the VM ~8x slower)
  pgrep -xq UTM || { open -a UTM; sleep 3; }
  local try i
  for try in 1 2; do
    [[ $(utm_state "$1") == started ]] || "$UTMCTL" start ${OMACVM_HEADLESS:+--hide} "$1" >/dev/null 2>&1 || true
    for ((i = 0; i < 60; i += 3)); do [[ $(utm_state "$1") == started ]] && return 0; sleep 3; done
    # After a long session UTM can stop answering start requests (they time out
    # with OSStatus -1712); restarting the app clears it. Never while another
    # UTM VM runs.
    (( try == 1 )) || break
    "$UTMCTL" list 2>/dev/null | awk 'NR > 1 && $2 == "started"' | grep -q . && break
    log "UTM did not start the VM: restarting UTM once"
    osascript -e 'quit app "UTM"' >/dev/null 2>&1 || true
    for ((i = 0; i < 30; i++)); do pgrep -xq UTM || break; sleep 1; done
    open -a UTM; sleep 5
  done
  die "UTM VM '$1' did not start (try quitting and reopening UTM, then run the omacvm command again)"
}

# utm_add_sound NAME: an Intel HDA sound card (speakers and microphone, through
# UTM's default SPICE audio), for VMs built without one. The VM must be
# stopped. UTM keeps the configuration it read at its start (it would start
# the VM without the card), so it is quit when no UTM VM runs (utm_start opens
# it again); otherwise the card comes with UTM's next start. VMs outside UTM's
# own folder: unchanged.
utm_add_sound() {
  local c="$UTM_DATA/Documents/$1.utm/config.plist" i
  [[ $(utm_data plutil -extract Sound json -o - "$c" 2>/dev/null) == "[]" ]] || return 0
  if pgrep -xq UTM; then
    if "$UTMCTL" list 2>/dev/null | awk 'NR > 1 && $2 == "started"' | grep -q .; then
      log "UTM: '$1' gets its sound card (speakers and microphone) when UTM starts next"
    else
      osascript -e 'quit app "UTM"' >/dev/null 2>&1 || true
      for ((i = 0; i < 30; i++)); do pgrep -xq UTM || break; sleep 1; done
    fi
  fi
  plutil -replace Sound -json '[{"Hardware":"intel-hda"}]' "$c" && log "UTM: a sound card for '$1' (speakers and microphone)"
}

utm_wait_stopped() {   # <vm name>
  local i
  for ((i = 0; i < 180; i += 3)); do [[ $(utm_state "$1") == stopped ]] && return 0; sleep 3; done
  die "UTM VM '$1' did not stop"
}

# ---- VMware Fusion ----
# Fusion's tools live in the app; its library is a text file, so listing VMs
# never starts Fusion. A VM is its .vmx; its name is displayName in there.
FUSION_LIB="/Applications/VMware Fusion.app/Contents/Library"
VMRUN=$FUSION_LIB/vmrun
FUSION_INVENTORY="$HOME/Library/Application Support/VMware Fusion/vmInventory"
FUSION_NETWORKING="/Library/Preferences/VMware Fusion/networking"
FUSION_LEASES=/var/db/vmware/vmnet-dhcpd-vmnet8.leases
FUSION_DIR=${OMACVM_FUSION_DIR:-$HOME/Virtual Machines.localized}   # where omacvm build puts new VMs

fusion_bundle() { echo "$FUSION_DIR/$1.vmwarevm"; }   # <vm name> -> the folder omacvm build gives it
fusion_version() { defaults read "/Applications/VMware Fusion.app/Contents/Info" CFBundleShortVersionString 2>/dev/null; }

fusion_list() {   # one line per VM: NAME<TAB>VMX
  local x n
  # Fusion's library, the running VMs and the VMs in $FUSION_DIR: a VM started
  # without a window (OMACVM_HEADLESS=1) never gets into the library.
  {
    [[ -f $FUSION_INVENTORY ]] && sed -n 's/^vmlist[0-9]*\.config = "\(.*\.vmx\)"$/\1/p' "$FUSION_INVENTORY"
    [[ -x $VMRUN ]] && "$VMRUN" list 2>/dev/null | grep '\.vmx$'
    for x in "$FUSION_DIR"/*.vmwarevm/*.vmx; do [[ -f $x ]] && echo "$x"; done
  } | awk '!seen[$0]++' | while IFS= read -r x; do
    [[ -f $x ]] || continue
    n=$(sed -n 's/^displayName = "\(.*\)"$/\1/p' "$x" | head -1)
    printf '%s\t%s\n' "${n:-$(basename "$x" .vmx)}" "$x"
  done
}

fusion_vmx() {   # <vm name> -> its .vmx (in Fusion's library, or one omacvm build made)
  local x
  x=$(fusion_list | awk -F'\t' -v n="$1" '$1 == n { print $2; exit }')
  [[ -n $x ]] || { x="$(fusion_bundle "$1")/$1.vmx"; [[ -f $x ]] || x=""; }
  [[ -n $x ]] && echo "$x"
}

fusion_state() {   # <vm name> -> running|stopped
  local x
  x=$(fusion_vmx "$1") || return 1
  if [[ -x $VMRUN ]] && "$VMRUN" list 2>/dev/null | grep -qxF "$x"; then echo running; else echo stopped; fi
}

# The Mac's address on Fusion's NAT network (vmnet8). Fusion picks the subnet
# at install time; the Mac is .1 there (the guests' gateway is .2). The first
# VNET_8_HOSTONLY_SUBNET line, and only a private address (the Bridge and
# Gestures read it the same way).
fusion_host() {
  local net
  net=$(awk '$1 == "answer" && $2 == "VNET_8_HOSTONLY_SUBNET" { print $3; exit }' "$FUSION_NETWORKING" 2>/dev/null)
  private_ipv4 "$net" || return 1
  [[ ${net%.*}.1 != 192.168.64.1 ]] || return 1   # UTM's
  echo "${net%.*}.1"
}
private_ipv4() {   # 10/8, 172.16/12 or 192.168/16, each part 0-255
  local a b c d
  [[ ${1:-} =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  a=${BASH_REMATCH[1]} b=${BASH_REMATCH[2]} c=${BASH_REMATCH[3]} d=${BASH_REMATCH[4]}
  (( a <= 255 && b <= 255 && c <= 255 && d <= 255 )) || return 1
  (( a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168) ))
}

fusion_ip() {   # <vm name> [seconds]: the address Fusion's DHCP gave the VM's MAC
  local x mac i ip
  x=$(fusion_vmx "$1") || return 1
  for ((i = 0; i < ${2:-1}; i += 3)); do
    mac=$(sed -n 's/^ethernet0\.generatedAddress = "\(.*\)"$/\1/p; s/^ethernet0\.address = "\(.*\)"$/\1/p' "$x" | head -1 | tr 'A-F' 'a-f')
    if [[ -n $mac ]]; then
      ip=$(awk -v m="$mac" '$1 == "lease" { ip = $2 } $1 == "hardware" && tolower($3) == m ";" { last = ip } END { print last }' "$FUSION_LEASES" 2>/dev/null)
      [[ -n $ip ]] && { echo "$ip"; return 0; }
    fi
    sleep 3
  done
  return 1
}

fusion_start() {   # <vm name>
  # Right after a shutdown Fusion can still hold the VM's files and leave a
  # start without effect (no error): check, and try again.
  local x i
  x=$(fusion_vmx "$1") || die "no VMware Fusion VM named '$1'"
  for ((i = 0; i < 5; i++)); do
    [[ $(fusion_state "$1") == running ]] && return 0
    "$VMRUN" -T fusion start "$x" "$([[ ${OMACVM_HEADLESS:-} == 1 ]] && echo nogui || echo gui)" >/dev/null 2>&1 || true
    sleep 3
  done
  [[ $(fusion_state "$1") == running ]] || die "VMware Fusion did not start '$1'"
}

# fusion_add_sound NAME: Fusion's HD Audio card (speakers and the Mac's
# microphone), for VMs built without one. The VM must be stopped.
fusion_add_sound() {
  local x k v kv
  x=$(fusion_vmx "$1") || return 0
  grep -q '^sound.present = "TRUE"' "$x" && return 0
  for kv in sound.present=TRUE sound.virtualDev=hdaudio sound.fileName=-1 sound.autodetect=TRUE; do
    k=${kv%%=*}; v=${kv#*=}
    sed -i '' "/^$(sed 's/\./\\./g' <<<"$k") /d" "$x"
    printf '%s = "%s"\n' "$k" "$v" >> "$x"
  done
  log "VMware Fusion: a sound card for '$1' (speakers and microphone)"
}

fusion_wait_stopped() {   # <vm name>
  local i
  for ((i = 0; i < 180; i += 3)); do [[ $(fusion_state "$1") == stopped ]] && return 0; sleep 3; done
  die "VMware Fusion VM '$1' did not stop"
}

# OmacVM's helpers listen on the Mac's address on each VM app's shared network:
# 10.211.55.2 (Parallels), 192.168.64.1 (UTM), the .1 of Fusion's NAT network
# (fusion_host). vm_network_ok TYPE [IP] says (on stderr) what to change when
# that network was moved.
vm_network_ok() {
  local a
  case $1 in
    parallels)
      a=$(prlsrvctl net info Shared 2>/dev/null | awk '/Parallels adapter/ { f = 1 } f && /IPv4 address:/ { print $3; exit }')
      if [[ -n $a && $a != 10.211.55.2 ]]; then
        printf 'Parallels'"'"'s shared network is at %s; OmacVM needs its default, 10.211.55.0/24 (the Mac at 10.211.55.2): set it back in Parallels Desktop > Settings > Network (Shared).\n' "$a" >&2
        return 1
      fi ;;
    utm)
      if [[ -n ${2:-} && $2 != 192.168.64.* ]]; then
        printf 'The UTM VM is at %s, outside UTM'"'"'s default shared network 192.168.64.0/24 (the Mac at 192.168.64.1), which OmacVM needs: give the VM the "Shared Network" mode with macOS'"'"'s default range.\n' "$2" >&2
        return 1
      fi ;;
    fusion)
      a=$(fusion_host) || {
        printf 'VMware Fusion has no NAT network (vmnet8) on this Mac: open VMware Fusion > Settings > Network.\n' >&2
        return 1
      }
      if [[ -n ${2:-} && ${2%.*} != "${a%.*}" ]]; then
        printf 'The VMware Fusion VM is at %s, outside Fusion'"'"'s NAT network (the Mac at %s), which OmacVM needs: give the VM the "Share with my Mac" network.\n' "$2" "$a" >&2
        return 1
      fi ;;
    app) ;;   # OmacVM.app: QEMU's user network, the Mac is always 127.0.0.1
    *) return 1 ;;
  esac
  return 0
}
