# Finding and reaching VMs from the Mac (sourced after mac.sh; bash 3.2).
#   vms_list                 one line per VM: NAME<TAB>parallels|utm|fusion|app<TAB>running|stopped|...
#                            (Parallels' and UTM's other states as they name them;
#                            unknown: UTM runs but does not answer this terminal)
#   vm_find_ip NAME TYPE [s] the VM's address (waits up to s seconds)
#   vm_probe IP              what the VM says about itself, as KEY=value lines:
#                            OMACVM_USER, OMACVM_VERSION (empty: no OmacVM yet),
#                            /etc/omacvm/env (OMACVM_VM_TYPE, OMACVM_FEATURE_*)
#   vm_boot NAME TYPE        start a stopped VM and wait for its address

UTM_PREFS=$HOME/Library/Containers/com.utmapp.UTM/Data/Library/Preferences/com.utmapp.UTM.plist
source "$(dirname "${BASH_SOURCE[0]}")/app.sh"

# utm_ctl_list: utmctl list, given 15 seconds. utmctl talks to UTM through
# AppleEvents: over SSH, or where this terminal may not control UTM, it fails;
# while macOS still asks about it, it waits up to 10 minutes.
utm_ctl_list() { perl -e 'alarm shift; exec @ARGV' 15 "$UTMCTL" list 2>/dev/null; }
UTM_NO_ANSWER="UTM did not answer: run omacvm in a terminal app on the Mac and allow it to control UTM"

vms_list() {
  local u=""
  if [[ -x $PRLCTL ]]; then
    "$PRLCTL" list -a -o status,name 2>/dev/null | awk 'NR > 1 { s = $1; $1 = ""; sub(/^ /, ""); print $0 "\tparallels\t" s }'
  fi
  if [[ -x $UTMCTL ]] && pgrep -xq UTM && u=$(utm_ctl_list); then
    awk 'NR > 1 { s = $2; $1 = ""; $2 = ""; sub(/^  /, ""); print $0 "\tutm\t" (s == "started" ? "running" : s) }' <<<"$u"
  elif [[ -f $UTM_PREFS ]]; then
    # UTM not running (utmctl would start it), or not answering: its VMs,
    # wherever they are, from UTM's registry; stopped, suspended when UTM saved
    # their state (UTM itself calls those "paused" once it runs), or unknown
    # while UTM runs.
    python3 - "$UTM_PREFS" "$(pgrep -xq UTM && echo unknown || echo stopped)" <<'PY' 2>/dev/null
import os, plistlib, sys
for entry in plistlib.load(open(sys.argv[1], "rb")).get("Registry", {}).values():
    path = (entry.get("Package") or {}).get("Path", "")
    if not os.path.isdir(path):
        continue
    try:
        name = plistlib.load(open(os.path.join(path, "config.plist"), "rb"))["Information"]["Name"]
    except Exception:
        name = os.path.basename(path)[:-4]
    state = sys.argv[2] if sys.argv[2] == "unknown" else ("suspended" if entry.get("Suspended") else "stopped")
    print(f"{name}\tutm\t{state}")
PY
  fi
  local n x
  while IFS=$'\t' read -r n x; do
    [[ -n $n ]] && printf '%s\tfusion\t%s\n' "$n" "$(fusion_state "$n")"
  done < <(fusion_list)
  app_list
}

# vm_pin NAME TYPE: gssh checks that VM's remembered SSH host key from now on
# (OMA_PIN_RESET=1: forget it first, once).
vm_pin() {
  OMA_PIN="$OMA_PINS/$2-$(printf %s "$1" | tr -c 'A-Za-z0-9._-' _)-$(printf %s "$1" | cksum | cut -d' ' -f1)"
  OMA_PIN_ARGS=$(printf -- '--vm %q' "$1")
  if [[ ${OMA_PIN_RESET:-} == 1 ]]; then rm -f "$OMA_PIN"; OMA_PIN_RESET=0; fi
  export OMA_PIN OMA_PIN_ARGS
}

# vm_marked NAME TYPE: OmacVM built this VM (its description says so) or set
# it up (OmacVM's icon in UTM's library). Any custom Finder icon on a Parallels
# VM is no proof: only the description counts there.
vm_marked() {
  local b x
  case $2 in
    parallels) b=$(vm_bundle "$1")
               grep -q "built by OmacVM" "$b/config.pvs" 2>/dev/null ;;
    utm) b=$(utm_bundle "$1") && { grep -q "built by OmacVM" "$b/config.plist" || [[ -f $b/Data/omacvm.png ]]; } ;;
    fusion) x=$(fusion_vmx "$1") && grep -q "built by OmacVM" "$x" ;;
    *) return 1 ;;
  esac
}

utm_bundle() {   # NAME -> its .utm (UTM's registry also knows VMs outside UTM's folder)
  local b
  b=$(python3 - "$UTM_PREFS" "$1" <<'PY' 2>/dev/null
import os, plistlib, sys
for e in plistlib.load(open(sys.argv[1], "rb")).get("Registry", {}).values():
    p = (e.get("Package") or {}).get("Path", "")
    try:
        if plistlib.load(open(os.path.join(p, "config.plist"), "rb"))["Information"]["Name"] == sys.argv[2]:
            print(p); break
    except Exception:
        pass
PY
)
  [[ -n $b ]] || b="$HOME/Library/Containers/com.utmapp.UTM/Data/Documents/$1.utm"
  [[ -f $b/config.plist ]] && echo "$b"
}

vm_find_ip() {   # NAME TYPE [seconds]
  case $2 in
    parallels) vm_ip "$(vm_bundle "$1")" "${3:-1}" ;;
    utm) utm_ip "$1" "${3:-1}" ;;
    fusion) fusion_ip "$1" "${3:-1}" ;;
    app) app_ip "$1" "${3:-1}" ;;
    *) return 1 ;;
  esac
}

vm_probe() {
  gssh "$1" 'U=$(getent passwd 1000 | cut -d: -f1); H=$(getent passwd 1000 | cut -d: -f6)
    grep -q "^OMACVM_USER=" /etc/omacvm/env 2>/dev/null || echo "OMACVM_USER=$U"
    echo "OMACVM_VERSION=$(cat /usr/local/share/omacvm/VERSION 2>/dev/null || { [ -r /etc/omacvm/env ] && echo 1.x; })"
    cat /etc/omacvm/env 2>/dev/null
    # set up before the choices were kept
    grep -q "^OMACVM_FEATURE_omanotch=" /etc/omacvm/env 2>/dev/null || { [ -x "$H/.local/bin/notchcast" ] && echo OMACVM_FEATURE_omanotch=on; }
    grep -q "^OMACVM_FEATURE_autologin=" /etc/omacvm/env 2>/dev/null || { [ -f /etc/sddm.conf.d/20-omacvm-autologin.conf ] && echo OMACVM_FEATURE_autologin=on; }
    grep -q "^OMACVM_FEATURE_thp_kernel=" /etc/omacvm/env 2>/dev/null || { pacman -Q linux-aarch64-thp >/dev/null 2>&1 && echo OMACVM_FEATURE_thp_kernel=on; }
    true' < /dev/null 2>/dev/null
}

vm_boot() {   # NAME TYPE
  case $2 in
    parallels) vm_start "$1" "$(vm_bundle "$1")" >&2; vm_ip "$(vm_bundle "$1")" 300 ;;
    utm) utm_add_sound "$1" >&2; utm_start "$1" >&2; utm_ip "$1" 300 ;;
    fusion) fusion_add_sound "$1" >&2; fusion_start "$1" >&2; fusion_ip "$1" 300 ;;
    app) app_start "$1" ;;
    *) return 1 ;;
  esac
}

# The SSH access OmacVM needs, for a VM that was not built by OmacVM (an
# Omarchy installed by hand from omarchy-mac): one command to run in the VM.
ssh_setup_command() {
  local net h
  case $1 in
    parallels) net=10.211.55.0/24 ;;
    utm) net=192.168.64.0/24 ;;
    fusion) h=$(fusion_host) || return 1; net=${h%.*}.0/24 ;;
    app) net=10.0.2.0/24 ;;
  esac
  printf "sudo bash -c 'install -d -m700 /root/.ssh && echo \"%s\" >> /root/.ssh/authorized_keys && pacman -S --needed --noconfirm openssh >/dev/null && systemctl enable --now sshd && { ufw allow from %s to any port 22 proto tcp comment \"omacvm: ssh from the Mac\" || true; }'" \
    "$(cat "${OMA_KEY:-$HOME/.ssh/omacvm}.pub")" "$net"
}

# resolve_vm [start|soft]: VM (name) -> TYPE and IP. No name: "Omarchy", else
# the only running VM. With "start", a stopped VM is started; without, IP stays
# empty for it. Exits 2 when it cannot tell which VM ("soft": returns 1).
resolve_vm() {
  local running list state
  list=$(vms_list)   # once: it can take 15 s while UTM does not answer
  if [[ -z ${VM:-} ]]; then
    if cut -f1 <<<"$list" | grep -qxF Omarchy; then VM=Omarchy
    else
      running=$(awk -F'\t' '$3 == "running" { print $1 }' <<<"$list")
      if [[ $(grep -c . <<<"$running") == 1 ]]; then VM=$running
      else
        [[ ${1:-} == soft ]] && return 1
        echo "omacvm: which VM? pass --vm NAME (your VMs: $(cut -f1 <<<"$list" | paste -sd, - | sed 's/,/, /g'))" >&2
        exit 2
      fi
    fi
  fi
  # vm_type_in exits 2 for a name in two apps, and has said so.
  [[ -n ${TYPE:-} ]] || TYPE=$(vm_type_in "$VM" <<<"$list") || {
    (( $? == 2 )) || echo "omacvm: no Parallels, UTM, VMware Fusion or OmacVM.app VM named '$VM'" >&2
    exit 2; }
  vm_pin "$VM" "$TYPE"
  IP=""
  state=$(awk -F'\t' -v n="$VM" -v t="$TYPE" '$1 == n && $2 == t { print $3; exit }' <<<"$list")
  # UTM does not answer: the VM may well run, so never start it
  [[ $state == unknown ]] && { echo "omacvm: '$VM': $UTM_NO_ANSWER" >&2; exit 3; }
  # DHCP leases outlive a stopped VM: only a running one has an address.
  if [[ $state == running ]]; then
    IP=$(vm_find_ip "$VM" "$TYPE" 30 2>/dev/null) || IP=""
  fi
  if [[ -z $IP && ${1:-} == start ]]; then
    local other
    if [[ $TYPE == app ]] && other=$(app_other_running "$VM"); then
      die "OmacVM.app runs one VM at a time: stop '$other' first"
    fi
    log "starting '$VM'" >&2
    IP=$(vm_boot "$VM" "$TYPE") || die "'$VM' did not get an address"
    wait_ssh "$IP" 300
  fi
}

# vm_type NAME -> parallels | utm | fusion | app (replaces mac.sh's, without
# starting UTM). A name in two apps (a Parallels VM and an OmacVM.app VM both
# called "OmacVM Test") is not guessed: exit 2 with a message, --vm-type picks.
# A name in one app twice: the running one, else a usable one, and an
# "invalid" Parallels VM (its files are gone) last.
vm_type() { vms_list | vm_type_in "$1"; }
vm_type_in() {   # NAME, vms_list's lines on stdin
  local list apps
  list=$(cat)
  apps=$(awk -F'\t' -v n="$1" '$1 == n && $3 != "invalid" && !seen[$2]++ { print $2 }' <<<"$list")
  if [[ $(grep -c . <<<"$apps") -gt 1 ]]; then
    echo "omacvm: there is a VM named '$1' in $(vm_app_names "$apps" and): pass $(sed 's/^/--vm-type /' <<<"$apps" | paste -sd, - | sed 's/,/ or /g') to say which" >&2
    return 2
  fi
  awk -F'\t' -v n="$1" '
    $1 == n { if ($3 == "running") run = $2
              else if ($3 == "invalid") bad = $2
              else if (!any) any = $2 }
    END { if (run) print run; else if (any) print any; else if (bad) print bad; else exit 1 }' <<<"$list"
}
vm_app_names() {   # "TYPE\nTYPE..." WORD -> "Parallels WORD OmacVM.app"
  local t out=""
  while read -r t; do
    case $t in parallels) t=Parallels ;; utm) t=UTM ;; fusion) t="VMware Fusion" ;; app) t=OmacVM.app ;; esac
    out=${out:+$out $2 }$t
  done <<<"$1"
  echo "$out"
}
