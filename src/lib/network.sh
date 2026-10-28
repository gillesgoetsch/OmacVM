# OmacVM.app's optional second, LAN-facing NIC. The primary NIC remains
# QEMU's private management network. Sourced by network.sh and feature truth.
network_interface_valid() { [[ $1 =~ ^en[0-9]{1,4}$ ]]; }
network_mac_valid() { [[ $1 =~ ^52:54:00(:[0-9a-f]{2}){3}$ && $1 != 52:54:00:12:34:56 ]]; }

# Sets NETWORK_MODE, NETWORK_INTERFACE and NETWORK_MAC. A malformed setting
# is an error, never permission to silently use shared networking instead.
network_read() {
  local k v ni=0 nm=0
  NETWORK_MODE=shared; NETWORK_INTERFACE=""; NETWORK_MAC=""
  [[ -e $1/bridged-network ]] || return 0
  while IFS='=' read -r k v || [[ -n $k ]]; do
    case $k in
      interface) NETWORK_INTERFACE=$v; ni=$((ni + 1)) ;;
      mac) NETWORK_MAC=$v; nm=$((nm + 1)) ;;
      *) return 2 ;;
    esac
  done < "$1/bridged-network"
  [[ $ni == 1 && $nm == 1 ]] && network_interface_valid "$NETWORK_INTERFACE" && network_mac_valid "$NETWORK_MAC" || return 2
  NETWORK_MODE=bridged
}

# Keep all other feature choices (including choices a newer app introduced).
network_feature_record() {
  local d=$1 v=$2 f out=""
  for f in $(cat "$d/features" 2>/dev/null); do
    [[ $f == bridged-network=* ]] || out+="$f "
  done
  printf '%sbridged-network=%s\n' "$out" "$v" > "$d/features.network-new" &&
    mv -f "$d/features.network-new" "$d/features"
}

network_install_helper() { "$R/src/net/mac/install.sh" --bridged-interface "$1"; }
network_prepare_guest() {
  # Install the boot-time service without restarting the VM.
  OMACVM_NETWORK_PREPARE=1 "$R/src/cmd/apply.sh" --vm "$1" --vm-type app --ip "$2" --no-mac --feature bridged-network=on --transaction --yes
}
network_enable() {   # DIR VM INTERFACE
  local d=$1 vm=$2 ifc=$3 m="" fast="" ip=""
  network_interface_valid "$ifc" || return 2
  network_read "$d" || return 2
  m=$NETWORK_MAC
  [[ -n $m || ! -e $d/bridged-network-mac ]] || m=$(cat "$d/bridged-network-mac")
  [[ -z $m ]] || network_mac_valid "$m" || return 2
  fast=$(sed -n 's/^mac=//p' "$d/fast-network" 2>/dev/null) || fast=""
  if [[ -n $m && $m == "$fast" ]]; then
    echo "omacvm network: the LAN and fast-network MAC addresses must differ" >&2; return 2
  fi
  if [[ -z $m ]]; then
    while :; do
      m=$(printf '52:54:00:%02x:%02x:%02x' $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)))
      network_mac_valid "$m" && [[ $m != "$fast" ]] && break
    done
  fi
  if ! ip=$(app_ip "$vm"); then
    if [[ $(cat "$d/bridged-network-ready" 2>/dev/null) != 1 ]]; then
      echo "omacvm network: start '$vm' first, then run this command again to prepare its guest network service; nothing was changed" >&2
      return 3
    fi
  fi
  network_install_helper "$ifc" || return $?
  if [[ -n $ip ]]; then
    network_prepare_guest "$vm" "$ip" || return $?
    printf '1\n' > "$d/bridged-network-ready.new" &&
      mv -f "$d/bridged-network-ready.new" "$d/bridged-network-ready" || return 1
  fi
  printf '%s\n' "$m" > "$d/bridged-network-mac.new" &&
    mv -f "$d/bridged-network-mac.new" "$d/bridged-network-mac" || return 1
  printf 'interface=%s\nmac=%s\n' "$ifc" "$m" > "$d/bridged-network.new" &&
    mv -f "$d/bridged-network.new" "$d/bridged-network" || return 1
  network_feature_record "$d" on
}

network_disable() {
  # Do not remove the identity or touch fast-network. The latter is the
  # person's shared-mode preference, restored on the next start.
  rm -f "$1/bridged-network" || return 1
  network_feature_record "$1" off
}
