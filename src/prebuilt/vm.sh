# omacvm build --prebuilt: the VM from a downloaded image (sourced by
# src/cmd/build.sh after the questions; uses its variables: TYPE VM VM_DIR
# CPUS MEM_GB DISK_GB GFX_GB U FULL HASH HOST KB TZ_MAC LANG_VM KEY).
#   prebuilt_make_vm      download, unpack, new identity, seed, start; sets IP (and PVM)
#   prebuilt_drop_seed    after omacvm apply: power off, detach and delete the seed, start

PB_SEED=""

prebuilt_make_vm() {
  local tmp b t0 dl
  step "Downloading the prebuilt VM ($(pb_gb "$PB_SIZE") GB, release $PB_TAG)"
  t0=$(date +%s)
  prebuilt_download
  dl=$(( $(date +%s) - t0 ))
  info "downloaded and checked in $(( dl / 60 ))m $(( dl % 60 ))s"
  PB_TIMES="download $(( dl / 60 ))m $(( dl % 60 ))s"

  step "Unpacking the VM and making it yours"
  t0=$(date +%s)
  case $TYPE in
    parallels) SEED_NET=10.211.55.0/24 ;;
    utm) SEED_NET=192.168.64.0/24; SEED_DISPLAY=$(swift "$R/src/display/mac-display.swift" 2>/dev/null || true) ;;
    fusion) b=$(fusion_host); SEED_NET=${b%.*}.0/24; SEED_DISPLAY=$(swift "$R/src/display/mac-display.swift" 2>/dev/null || true) ;;
  esac
  case $TYPE in
    parallels)
      tmp="$VM_DIR/.omacvm-unpack-$$"
      ui_spin "Unpacking" prebuilt_unpack "$tmp" || die "could not unpack the image (free disk space?)"
      PVM="$VM_DIR/$VM.pvm"
      mv "$tmp/$PB_BUNDLE" "$PVM"; rmdir "$tmp"
      pb_disk_bigger "$DISK_GB" && /usr/local/bin/prl_disk_tool resize --hdd "$PVM/omarchy.hdd" --size "${DISK_GB}G" >/dev/null
      mkdir -p "$HOME/.local/share/omacvm/clip"
      python3 "$R/src/prebuilt/vmconfig.py" pvs-identity "$PVM/config.pvs" "$VM" "$PVM" \
        "$HOME/.local/share/omacvm/clip" "$CPUS" $((MEM_GB * 1024)) $((DISK_GB * 1024))
      python3 "$R/src/vm/pvs.py" "$PVM/config.pvs" omacvm --cpus "$CPUS" --memsize $((MEM_GB * 1024)) \
        --description "Omarchy (omarchy-mac) on Arch Linux ARM, built by OmacVM (prebuilt)"
      PB_SEED="$PVM/omacvm-seed.iso"
      prebuilt_seed "$PB_SEED"
      python3 "$R/src/prebuilt/vmconfig.py" pvs-seed "$PVM/config.pvs" "$PB_SEED"
      cp "$PVM/config.pvs" "$PVM/config.pvs.backup"
      "$PRLCTL" register "$PVM" >/dev/null
      info "set up in $(( $(date +%s) - t0 ))s"; PB_TIMES+=", unpack $(( $(date +%s) - t0 ))s"
      step "First boot: your user, keys, keyboard and timezone"
      t0=$(date +%s)
      vm_start "$VM" "$PVM"
      ui_spin_val IP "The VM starts and gets its address" vm_ip "$PVM" 300 || die "the VM got no IP address" ;;
    utm)
      tmp="$PREBUILT_CACHE/unpack-$$"
      ui_spin "Unpacking" prebuilt_unpack "$tmp" || die "could not unpack the image (free disk space?)"
      b="$tmp/$VM.utm"
      mv "$tmp/$PB_BUNDLE" "$b"
      python3 "$R/src/prebuilt/vmconfig.py" utm-identity "$b/config.plist" "$VM" "$CPUS" $((MEM_GB * 1024))
      prebuilt_seed "$b/Data/omacvm-seed.iso"
      python3 "$R/src/prebuilt/vmconfig.py" utm-seed "$b/config.plist" omacvm-seed.iso
      if pb_disk_bigger "$DISK_GB"; then
        python3 "$R/src/prebuilt/vmconfig.py" qcow2-grow "$b/Data/$(plutil -extract Drive.0.ImageName raw "$b/config.plist")" $((DISK_GB * 1024))
      fi
      utm_tune_app
      pgrep -xq UTM || { open -a UTM; sleep 3; }
      utm_import "$b"
      rm -rf "$tmp"
      PB_SEED="$UTM_DOCS/$VM.utm/Data/omacvm-seed.iso"
      info "set up in $(( $(date +%s) - t0 ))s"; PB_TIMES+=", unpack $(( $(date +%s) - t0 ))s"
      step "First boot: your user, keys, keyboard and timezone"
      t0=$(date +%s)
      utm_start "$VM"
      ui_spin_val IP "The VM starts and gets its address" utm_ip "$VM" 300 || die "the VM got no IP address" ;;
    fusion)
      mkdir -p "$FUSION_DIR"
      tmp="$FUSION_DIR/.omacvm-unpack-$$"
      ui_spin "Unpacking" prebuilt_unpack "$tmp" || die "could not unpack the image (free disk space?)"
      b=$(fusion_bundle "$VM")
      mv "$tmp/$PB_BUNDLE" "$b"; rmdir "$tmp"
      mv "$b/$PREBUILT_NAME.vmx" "$b/$VM.vmx"
      [[ -f $b/$PREBUILT_NAME.nvram ]] && mv "$b/$PREBUILT_NAME.nvram" "$b/$VM.nvram"
      vmx_set "$b/$VM.vmx" nvram "$VM.nvram"
      pb_disk_bigger "$DISK_GB" && "$FUSION_LIB/vmware-vdiskmanager" -x "${DISK_GB}GB" "$b/omarchy.vmdk" >/dev/null
      read -r n w h < <(fusion_mac_displays)
      python3 "$R/src/prebuilt/vmconfig.py" vmx-identity "$b/$VM.vmx" "$VM" "$CPUS" $((MEM_GB * 1024)) "$GFX_GB" "$n" "$w" "$h"
      PB_SEED="$b/omacvm-seed.iso"
      prebuilt_seed "$PB_SEED"
      python3 "$R/src/prebuilt/vmconfig.py" vmx-seed "$b/$VM.vmx" "$PB_SEED"
      info "set up in $(( $(date +%s) - t0 ))s"; PB_TIMES+=", unpack $(( $(date +%s) - t0 ))s"
      step "First boot: your user, keys, keyboard and timezone"
      t0=$(date +%s)
      fusion_start "$VM"
      ui_spin_val IP "The VM starts and gets its address" fusion_ip "$VM" 300 || die "the VM got no IP address" ;;
  esac
  prebuilt_cleanup
  # The image has no SSH host keys: the first boot makes them, and OmacVM
  # remembers them from here on (a VM of that name before this one: its key goes).
  export OMA_PIN_NEW=1
  OMA_PIN_RESET=1 vm_pin "$VM" "$TYPE"
  ui_spin "Waiting for SSH on $IP (the first boot sets up your user)" wait_ssh "$IP" 600 || die "no SSH on $IP"
  gssh "$IP" "cat /var/log/omacvm-firstboot.log 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep '^==>' | sed 's/^==> /    /'" || true
  PB_TIMES+=", first boot $(( $(date +%s) - t0 ))s"
  # Parallels Tools: omacvm apply installs them from this Mac's Parallels.
}

prebuilt_drop_seed() {
  log "removing the seed (it held your password hash)"
  gssh "$IP" "systemctl poweroff" 2>/dev/null || true
  case $TYPE in
    parallels)
      ui_spin "The VM shuts down" wait_stopped "$VM"
      "$PRLCTL" unregister "$VM" >/dev/null
      python3 "$R/src/prebuilt/vmconfig.py" pvs-seed "$PVM/config.pvs" -
      rm -f "$PB_SEED" "$PVM"/*.mem "$PVM"/*.mem.sh "$PVM/vm.lock"
      cp "$PVM/config.pvs" "$PVM/config.pvs.backup"
      "$PRLCTL" register "$PVM" >/dev/null
      vm_start "$VM" "$PVM" ;;
    utm)
      ui_spin "The VM shuts down" utm_wait_stopped "$VM"
      utm_drop_live "$VM"
      rm -f "$PB_SEED"
      utm_set_icon "$VM"   # after the last configuration change: UTM's scripting refuses custom icons
      utm_add_sound "$VM"  # images from before 2.6.0 have no sound card
      utm_start "$VM" ;;
    fusion)
      ui_spin "The VM shuts down" fusion_wait_stopped "$VM"
      python3 "$R/src/prebuilt/vmconfig.py" vmx-seed "$(fusion_vmx "$VM")" -
      rm -f "$PB_SEED"
      fusion_add_sound "$VM"   # images from before 2.6.0 have no sound card
      fusion_start "$VM" ;;
  esac
}
