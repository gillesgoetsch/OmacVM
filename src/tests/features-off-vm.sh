#!/bin/bash
# Off means off, in a running VM: for every feature the VM has switched off,
# nothing of it runs in the VM, the VM tries no connection to the Mac for it
# (counted for a while with an nftables counter), and omacvm check says "off"
# for it. Read-only
# but for the counter table, which goes again. The desktop user must be logged in.
#   src/tests/features-off-vm.sh --vm NAME [--vm-type TYPE] [--seconds 30]
# Exits 1 if anything that is off still runs, connects or checks as on.
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
VM=""; TYPE=""; SECS=30
while (( $# )); do
  case $1 in
    --vm) VM=$2; shift 2 ;;
    --vm-type) TYPE=$2; shift 2 ;;
    --seconds) SECS=$2; shift 2 ;;
    *) sed -n '7s/^# \{0,1\}//p' "$0" >&2; exit 2 ;;
  esac
done
[[ -n $VM && $SECS =~ ^[0-9]+$ ]] || { sed -n '7s/^# \{0,1\}//p' "$0" >&2; exit 2; }
source "$R/src/lib/mac.sh"
source "$R/src/lib/vm.sh"
resolve_vm
[[ -n $IP ]] || { echo "features-off-vm: '$VM' is not running" >&2; exit 1; }
echo "$TYPE VM '$VM' at $IP: watching its links to the Mac for $SECS s"

gssh "$IP" "bash -s -- $SECS" <<'GUEST'
set -uo pipefail
SECS=$1
source /etc/omacvm/env
U=$OMACVM_USER; H=$(getent passwd "$U" | cut -d: -f6); HOST=$OMACVM_HOST; TYPE=$OMACVM_VM_TYPE
f() { local v; v=$(sed -n "s/^OMACVM_FEATURE_${1//-/_}=//p" /etc/omacvm/env | tail -1); echo "${v:-off}"; }
fail=0
ok()  { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }
user_ctl() { systemctl --user -M "$U@" "$@" 2>/dev/null; }
sys_off() {   # FEATURE UNIT: a system unit neither enabled nor running
  if systemctl is-active -q "$2" 2>/dev/null || systemctl is-enabled -q "$2" 2>/dev/null; then
    bad "$1 off: $2 is $(systemctl is-active "$2" 2>/dev/null)/$(systemctl is-enabled "$2" 2>/dev/null)"
  else ok "$1 off: $2 not enabled, not running"; fi
}
user_off() {   # FEATURE UNIT: a user unit neither enabled nor running for $U
  local a e
  a=$(user_ctl is-active "$2"); e=$(user_ctl is-enabled "$2")
  if [[ $a == active || $a == activating || $e == enabled || $(systemctl --global is-enabled "$2" 2>/dev/null) == enabled ]]; then
    bad "$1 off: $2 is ${a:-?}/${e:-?} (global: $(systemctl --global is-enabled "$2" 2>/dev/null))"
  else ok "$1 off: $2 not enabled, not running"; fi
}
proc_off() {   # FEATURE PATTERN: no such process
  local p; p=$(pgrep -a -f -- "$2" | grep -v pgrep | head -1)
  if [[ -n $p ]]; then bad "$1 off: runs: $p"; else ok "$1 off: no $2 process"; fi
}

# Who may talk to the Mac on which port: Omanotch 47811, Gestures 47830,
# Bridge 47831.
want=()
[[ $(f omanotch) == on ]] && want+=(47811)
[[ $(f gestures) == on ]] && want+=(47830)
if [[ $(f bridge) == on ]]; then want+=(47831); fi

[[ $(f gestures) == off ]] && { sys_off gestures omacvm-gestures; proc_off gestures "omacvm-gestures"; }
if [[ $(f omanotch) == off ]]; then
  user_off omanotch notchcast.service; user_off omanotch omacvm-omanotch.service; proc_off omanotch "$H/.local/bin/notchcast"
  [[ -e $H/.local/bin/notchcast ]] && bad "omanotch off: $H/.local/bin/notchcast is still there" || ok "omanotch off: no notchcast"
fi
if [[ $(f bridge) == off ]]; then
  for u in omacvm-bridge-osd.service omacvm-bridge-events.socket omacvm-bridge-events.service; do user_off bridge "$u"; done
  proc_off bridge "omacvm-bridge events"
  w=$(jq -r '[.bar.layout[]?[]?.id | select(. == "omacvm.bluetooth" or . == "omacvm.wifi" or . == "omacvm.audio" or . == "omacvm.nightshift")] | join(" ")' "$H/.config/omarchy/shell.json" 2>/dev/null)
  [[ -z $w ]] && ok "bridge off: no Bridge widgets in the bar" || bad "bridge off: widgets in the bar: $w"
fi
[[ $(f wallpaper) == off ]] && { user_off wallpaper omacvm-wallpaper.path; user_off wallpaper omacvm-wallpaper.service; }
if [[ $(f camera) == off ]]; then user_off camera omacvm-camera.service; proc_off camera "/usr/local/bin/omacvm-camera"; fi
if [[ $(f battery) == off ]]; then sys_off battery omacvm-battery; proc_off battery "/usr/local/bin/omacvm-battery"; fi
if [[ $(f fast-network) == off && $TYPE == app ]]; then
  gw=$(ip -4 route show default | awk '{ print $3; exit }')
  [[ $gw != 192.168.77.1 ]] && ok "fast-network off: on QEMU's user network ($gw)" || bad "fast-network off: the VM is on vmnet"
fi
if [[ $(f scroll-momentum) == off ]]; then
  grep -qxF 'require("hypr.omacvm_glide")' "$H/.config/hypr/hyprland.lua" 2>/dev/null &&
    bad "scroll-momentum off: omacvm_glide.lua still loaded" || ok "scroll-momentum off: not loaded"
fi

# Every new connection the VM starts towards the Mac, for a while. With
# OmacVM.app's fast network the Mac is its gateway.
gw=$(ip -4 route show default | awk '{ print $3; exit }')
[[ $TYPE == app && $gw == 192.168.77.1 ]] && HOST=$gw
T=omacvm_off_test
nft delete table inet $T 2>/dev/null
nft -f - <<NFT
table inet $T {
  chain out {
    type filter hook output priority 0; policy accept;
    ip daddr $HOST tcp dport 47811 tcp flags & (syn | ack) == syn counter comment "p47811"
    ip daddr $HOST tcp dport 47830 tcp flags & (syn | ack) == syn counter comment "p47830"
    ip daddr $HOST tcp dport 47831 tcp flags & (syn | ack) == syn counter comment "p47831"
    ip daddr $HOST tcp dport != { 47811, 47830, 47831 } tcp flags & (syn | ack) == syn counter comment "pother"
  }
}
NFT
sleep "$SECS"
counts=$(nft list chain inet $T out | sed -n 's/.*counter packets \([0-9]*\) .*comment "p\([a-z0-9]*\)".*/\2 \1/p')
nft delete table inet $T
while read -r port n; do
  case $port in
    47811) name=omanotch ;; 47830) name=gestures ;; 47831) name="bridge (camera, battery)" ;; *) name="other ports" ;;
  esac
  if [[ $port != other && " ${want[*]-} " == *" $port "* ]]; then ok "$name on: $n new connection(s) to $HOST:$port"
  elif (( n > 0 )); then bad "$name off: $n new connection(s) to $HOST:$port in $SECS s"
  else ok "$name: no connection to $HOST:$port in $SECS s"; fi
done <<<"$counts"

# omacvm check in the VM: no failure, and off where off.
out=$(bash /usr/local/share/omacvm/guest/check.sh --user "$U" --tsv 2>/dev/null)
rows() { awk -F'\t' -v n="$1" '$1 != "section" && $2 == n { print $1 ": " $3 }' <<<"$out"; }
off_row() {   # FEATURE CHECK-NAME
  local r; r=$(rows "$2")
  if [[ -z $r ]]; then bad "$1 off: omacvm check has no '$2' line"
  elif [[ $r == skip:*off* ]]; then ok "$1 off: check says '$r'"
  else bad "$1 off: check says '$r'"; fi
}
[[ $(f bridge) == off ]] && off_row bridge Bridge
[[ $(f gestures) == off ]] && off_row gestures "trackpad gestures"
[[ $(f omanotch) == off ]] && off_row omanotch Omanotch
[[ $(f camera) == off ]] && off_row camera camera
[[ $(f battery) == off ]] && off_row battery battery
[[ $(f wallpaper) == off && $(f bridge) == on ]] && off_row wallpaper wallpaper
[[ $(f mac-clock) == off ]] && off_row mac-clock "the Mac's clock"
[[ $(f fast-network) == off && $TYPE == app ]] && off_row fast-network "fast network"
[[ $(f scroll-momentum) == off ]] && off_row scroll-momentum "scroll momentum"
f=$(awk -F'\t' '$1 == "fail" { print $2 ": " $3 }' <<<"$out")
[[ -z $f ]] && ok "omacvm check in the VM: no failures" || while IFS= read -r l; do bad "check: $l"; done <<<"$f"
exit $fail
GUEST
