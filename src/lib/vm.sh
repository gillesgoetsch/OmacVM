# Finding and reaching VMs from the Mac (sourced after mac.sh; bash 3.2).
#   vms_list                 one line per VM: NAME<TAB>app<TAB>running|stopped, then
#                            NAME<TAB>parallels|utm|fusion<TAB>retired (retired.sh)
#   vm_find_ip NAME TYPE [s] the VM's address (waits up to s seconds)
#   vm_probe IP              what the VM says about itself, as KEY=value lines:
#                            OMACVM_USER, OMACVM_VERSION (empty: no OmacVM yet),
#                            /etc/omacvm/env (OMACVM_VM_TYPE, OMACVM_FEATURE_*)
#   vm_boot NAME TYPE        start a stopped VM and wait for its address

source "$(dirname "${BASH_SOURCE[0]}")/app.sh"
source "$(dirname "${BASH_SOURCE[0]}")/retired.sh"

vms_list() {
  app_list || :   # its status says nothing here; under set -e it must not end the list
  retired_list
}

# vm_pin NAME TYPE: gssh checks that VM's remembered SSH host key from now on
# (OMA_PIN_RESET=1: forget it first, once), and offers an OmacVM.app VM's own
# key (OMA_VM_KEY).
vm_pin() {
  OMA_PIN="$OMA_PINS/$2-$(printf %s "$1" | tr -c 'A-Za-z0-9._-' _)-$(printf %s "$1" | cksum | cut -d' ' -f1)"
  OMA_PIN_ARGS=$(printf -- '--vm %q' "$1")
  if [[ ${OMA_PIN_RESET:-} == 1 ]]; then rm -f "$OMA_PIN"; OMA_PIN_RESET=0; fi
  # An OmacVM.app VM's own SSH key (app_ssh_key): gssh offers it first.
  local d
  OMA_VM_KEY=""
  if [[ $2 == app ]] && d=$(app_dir "$1" 2>/dev/null) && [[ -f $d/ssh-key ]]; then OMA_VM_KEY=$d/ssh-key; fi
  export OMA_PIN OMA_PIN_ARGS OMA_VM_KEY
}

vm_find_ip() {   # NAME TYPE [seconds]
  [[ $2 == app ]] && app_ip "$1" "${3:-1}"
}

# vm_probe IP: the VM's OmacVM settings over SSH (nothing when SSH did not
# get in). OMA_PROBE_ERR=FILE: ssh's own messages go there (ssh_failure_why).
vm_probe() {
  gssh "$1" 'U=$(getent passwd 1000 | cut -d: -f1); H=$(getent passwd 1000 | cut -d: -f6)
    grep -q "^OMACVM_USER=" /etc/omacvm/env 2>/dev/null || echo "OMACVM_USER=$U"
    echo "OMACVM_VERSION=$(cat /usr/local/share/omacvm/VERSION 2>/dev/null || { [ -r /etc/omacvm/env ] && echo 1.x; })"
    cat /etc/omacvm/env 2>/dev/null
    # set up before the choices were kept
    grep -q "^OMACVM_FEATURE_omanotch=" /etc/omacvm/env 2>/dev/null || { [ -x "$H/.local/bin/notchcast" ] && echo OMACVM_FEATURE_omanotch=on; }
    grep -q "^OMACVM_FEATURE_autologin=" /etc/omacvm/env 2>/dev/null || { [ -f /etc/sddm.conf.d/20-omacvm-autologin.conf ] && echo OMACVM_FEATURE_autologin=on; }
    grep -q "^OMACVM_FEATURE_thp_kernel=" /etc/omacvm/env 2>/dev/null || { pacman -Q linux-aarch64-thp >/dev/null 2>&1 && echo OMACVM_FEATURE_thp_kernel=on; }
    # The memory-optimized kernel it has (apply asks before a newer one is built).
    echo "OMACVM_THP_KERNEL=$(pacman -Q linux-aarch64-thp 2>/dev/null | cut -d" " -f2)"
    echo "OMACVM_NPROC=$(nproc 2>/dev/null)"
    # A move to Omarchy 4.5 began here and its package switch is not done (apply stops: OmacVM.app).
    m=/usr/local/share/omacvm/guest/omarchy-move.sh
    [ -x "$m" ] && "$m" pending >/dev/null 2>&1 && echo OMACVM_MOVE_PENDING=1
    # Autologin as SDDM does it, whoever wrote the file (src/guest/autologin.sh: the same rule).
    if [ -d /etc/sddm.conf.d ] || [ -f /etc/sddm.conf ]; then
      u=$(cat /usr/lib/sddm/sddm.conf.d/*.conf /etc/sddm.conf.d/*.conf /etc/sddm.conf 2>/dev/null |
        awk "/^[[:space:]]*\\[/ { s = (\$0 ~ /^[[:space:]]*\\[Autologin\\]/) } s && /^[[:space:]]*User[[:space:]]*=/ { sub(/^[^=]*=[[:space:]]*/, \"\"); sub(/[[:space:]]+\$/, \"\"); u = \$0 } END { print u }")
      [ -n "$u" ] && echo OMACVM_REAL_autologin=on || echo OMACVM_REAL_autologin=off
    fi
    true' < /dev/null 2>"${OMA_PROBE_ERR:-/dev/null}"
}

vm_boot() {   # NAME TYPE
  [[ $2 == app ]] && app_start "$1"
}

# The SSH access OmacVM needs, for a VM that knows another Mac's key: one
# command to run in the VM.
#   ssh_setup_command TYPE [PUBLIC_KEY_FILE]   (default: this Mac's key; an app
#   VM's folder key for app VMs). OmacVM.app's Copy Command builds the same
#   (SSHRepair.manualCommand). The sshd restart clears its PerSourcePenalties
#   for the Mac's earlier tries.
ssh_setup_command() {
  local net=10.0.2.0/24
  printf "sudo bash -c 'install -d -m700 /root/.ssh && echo \"%s\" >> /root/.ssh/authorized_keys && { pacman -Q openssh >/dev/null 2>&1 || pacman -S --noconfirm openssh >/dev/null; } && systemctl enable sshd && systemctl restart sshd && { ufw allow from %s to any port 22 proto tcp comment \"omacvm: ssh from the Mac\" || true; }'" \
    "$(head -1 "${2:-${OMA_KEY:-$HOME/.ssh/omacvm}.pub}")" "$net"
}

# resolve_vm [start|soft]: VM (name) -> TYPE and IP. No name: the OmacVM.app
# VM "Omarchy", else the only running one. A stopped VM keeps IP empty. Only
# "start" starts one, and only one the caller named (--vm): a command that
# changes a VM. A VM picked by default is never started, so a command run
# without --vm never boots the person's VM (exit 3 says so). Exits 2 when it
# cannot tell which VM ("soft": returns 1). A retired Parallels, UTM or
# VMware Fusion VM: exit 3 with the text of retired.sh, nothing done to it.
resolve_vm() {
  local running list apps state named=0
  [[ -n ${VM:-} ]] && named=1
  list=$(vms_list)
  apps=$(awk -F'\t' '$2 == "app"' <<<"$list")
  if [[ -z ${VM:-} ]]; then
    if cut -f1 <<<"$apps" | grep -qxF Omarchy; then VM=Omarchy
    else
      running=$(awk -F'\t' '$3 == "running" { print $1 }' <<<"$apps")
      if [[ $(grep -c . <<<"$running") == 1 ]]; then VM=$running
      elif awk -F'\t' '$1 == "Omarchy" { f = 1 } END { exit !f }' <<<"$list"; then
        [[ ${1:-} == soft ]] && return 1
        retired_stop Omarchy "$(awk -F'\t' '$1 == "Omarchy" { print $2; exit }' <<<"$list")"
      else
        [[ ${1:-} == soft ]] && return 1
        echo "omacvm: which VM? pass --vm NAME (your VMs: $(cut -f1 <<<"$apps" | paste -sd, - | sed 's/,/, /g'))" >&2
        exit 2
      fi
    fi
  fi
  if [[ -n ${TYPE:-} ]] && route_retired "$TYPE"; then
    awk -F'\t' -v n="$VM" -v t="$TYPE" '$1 == n && $2 == t { f = 1 } END { exit !f }' <<<"$list" &&
      retired_stop "$VM" "$TYPE"
    echo "omacvm: no $(retired_name "$TYPE") VM of OmacVM's named '$VM'" >&2
    exit 2
  fi
  [[ -n ${TYPE:-} ]] || TYPE=$(vm_type_in "$VM" <<<"$list") || {
    echo "omacvm: no OmacVM.app VM named '$VM'" >&2
    exit 2; }
  route_retired "$TYPE" && retired_stop "$VM" "$TYPE"
  vm_pin "$VM" "$TYPE"
  IP=""
  state=$(awk -F'\t' -v n="$VM" -v t="$TYPE" '$1 == n && $2 == t { print $3; exit }' <<<"$list")
  # DHCP leases outlive a stopped VM: only a running one has an address.
  if [[ $state == running ]]; then
    IP=$(vm_find_ip "$VM" "$TYPE" 30 2>/dev/null) || IP=""
  fi
  if [[ -z $IP && ${1:-} == start ]]; then
    local other
    if (( ! named )); then
      echo "omacvm: '$VM' is off, and it was not named: start it, or pass --vm \"$VM\" to have it started" >&2
      exit 3
    fi
    if other=$(app_other_running "$VM"); then
      die "OmacVM.app runs one VM at a time: stop '$other' first"
    fi
    # Never with an app older than the VM's OmacVM, or none (app_boot_app says why).
    app_boot_app "$VM" >/dev/null || exit 3
    log "starting '$VM'" >&2
    IP=$(vm_boot "$VM" "$TYPE") || die "'$VM' did not get an address"
    wait_ssh "$IP" 300
  fi
}

# vm_type NAME -> app, or parallels | utm | fusion for a retired VM. An
# OmacVM.app VM wins over a retired VM of the same name (that is never "a name
# in two apps"). A name in one app twice: the running one first.
vm_type() { vms_list | vm_type_in "$1"; }
vm_type_in() {   # NAME, vms_list's lines on stdin
  awk -F'\t' -v n="$1" '
    $1 == n { if ($2 == "app" && $3 == "running") run = $2
              else if ($2 == "app") any = $2
              else if (!old) old = $2 }
    END { if (run) print run; else if (any) print any; else if (old) print old; else exit 1 }'
}
