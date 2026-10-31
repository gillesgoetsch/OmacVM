#!/bin/bash
# Make a prebuilt OmacVM image for one route, for a GitHub release.
#
#   src/prebuilt/make-image.sh parallels|utm|fusion|app [STAGE...]
#
# Stages (all of them, in this order, when none is given):
#   build       omacvm build --image: a normal build with a placeholder user and
#               nothing of this Mac (no Bridge token, no Parallels Tools)
#   generalize  in the VM: remove the user, keys, logs and caches, install the
#               first-boot service, check for personal data, zero the free space
#   package     compact the disk, copy the bundle without logs or Mac paths,
#               tar + zstd -19, split into 1.9 GB parts, manifest (signed with
#               the release key: src/release/release-key.sh) + SHA-256 sums
#   repack      the packed image again with this checkout's configuration edits
#   upload      to the GitHub release $OMACVM_PREBUILT_TAG (default
#               prebuilt-VERSION), created as a pre-release if missing
#   clean       delete the image VM (only the one this script made)
#
# Output: ~/Library/Caches/omacvm/prebuilt-out/<route>/ (or $OMACVM_PREBUILT_OUT).
# Resources: 8 CPUs, 12 GB memory, a 64 GB disk (grown on install).
# app: OmacVM.app's own create script from this checkout (app/scripts, with
# the QEMU runtime built: app/scripts/build-app.sh), the VM in <output>/vm,
# headless, without a window and without the Mac's helpers.
# OMACVM_PREBUILT_APP=/path/OmacVM.app (app): that app's own scripts and
# runtime instead (Contents/Resources), as the app makes a VM; for an app built
# on another Mac, which leaves no runtime build here (src/release/release.sh).
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
source "$R/src/lib/mac.sh"
source "$R/src/lib/vm.sh"
source "$R/src/vm/fusion.sh"
source "$R/src/prebuilt/lib.sh"

ROUTE=${1:-}; shift || true
case $ROUTE in parallels|utm|fusion|app) ;; *) sed -n '2,26s/^# \{0,1\}//p' "$0"; exit 2 ;; esac
STAGES=("$@"); (( ${#STAGES[@]} )) || STAGES=(build generalize package)
VERSION=$(cat "$R/src/VERSION")
case $ROUTE in parallels) VM="OmacVM Image Parallels" ;; utm) VM="OmacVM Image UTM" ;; fusion) VM="OmacVM Image Fusion" ;; app) VM="OmacVM Image App" ;; esac
OUT=${OMACVM_PREBUILT_OUT:-$HOME/Library/Caches/omacvm/prebuilt-out}/$ROUTE
WORK=$OUT/work
TAG=${OMACVM_PREBUILT_TAG:-prebuilt-$VERSION}
export OMA_KEY=$HOME/.ssh/omacvm
mkdir -p "$OUT"
# OmacVM.app's image VM: its folder, and no way to the Mac's helpers.
APPVM=$OUT/vm
export OMACVM_HOST_PORTS=""
# The app's VM scripts (create-vm.sh, vm-common.sh): this checkout's, or those
# of OMACVM_PREBUILT_APP, which find the runtime inside that app.
APPSCRIPTS=$R/app/scripts
if [[ -n ${OMACVM_PREBUILT_APP:-} ]]; then
  [[ $ROUTE == app ]] || die "OMACVM_PREBUILT_APP is for the app route only"
  [[ $OMACVM_PREBUILT_APP == /* ]] || die "OMACVM_PREBUILT_APP must be an absolute path, not $OMACVM_PREBUILT_APP"
  [[ -f $OMACVM_PREBUILT_APP/Contents/Resources/scripts/create-vm.sh ]] || die "OMACVM_PREBUILT_APP: no OmacVM.app with its scripts at $OMACVM_PREBUILT_APP"
  appv=$(plutil -extract CFBundleShortVersionString raw -o - "$OMACVM_PREBUILT_APP/Contents/Info.plist" 2>/dev/null || true)
  [[ $appv == "$VERSION" ]] || die "OMACVM_PREBUILT_APP is OmacVM ${appv:-?}, this checkout $VERSION"
  APPSCRIPTS=$OMACVM_PREBUILT_APP/Contents/Resources/scripts
fi

bundle() {   # the image VM's bundle on this Mac
  case $ROUTE in
    parallels) vm_bundle "$VM" ;;
    utm) echo "$UTM_DOCS/$VM.utm" ;;
    fusion) fusion_bundle "$VM" ;;
    app) echo "$APPVM" ;;
  esac
}
vm_ip_now() {
  if [[ $ROUTE == app ]]; then echo "127.0.0.1:$(app_env "$APPVM" SSH_PORT)"; return; fi
  vm_find_ip "$VM" "$ROUTE" "${1:-1}"
}
running() {
  if [[ $ROUTE == app ]]; then app_running_dir "$APPVM"; return; fi
  vms_list | awk -F'\t' -v n="$VM" '$1 == n && $3 == "running" { f = 1 } END { exit !f }'
}
wait_off() {
  local i
  case $ROUTE in
    parallels) wait_stopped "$VM" ;;
    utm) utm_wait_stopped "$VM" ;;
    fusion) fusion_wait_stopped "$VM" ;;
    app) for ((i = 0; i < 300; i += 2)); do running || return 0; sleep 2; done; die "$VM did not power off" ;;
  esac
}
# The app's image VM without a window, as its create script runs it (a subshell:
# vm-common.sh has its own log and die).
app_boot() {
  ( source "$APPSCRIPTS/vm-common.sh"; vm_load "$APPVM"
    qemu_headless image "${QEMU_UEFI[@]}" -drive "$DISK_OPT" -device nvme,serial=omacvm,drive=disk,bootindex=0 )
}

stage_build() {
  rm -f "$OUT/omarchy-version" "$OUT/packages.txt"
  if [[ $ROUTE == app ]]; then stage_build_app; return; fi
  vms_list | cut -f1 | grep -qxF "$VM" && die "'$VM' exists: delete it first (make-image.sh $ROUTE clean)"
  log "build: $VM"
  OMACVM_PASSWORD=$(openssl rand -hex 16) "$R/omacvm" build --image --vm-type "$ROUTE" --vm-name "$VM" \
    --cpus 8 --memory-gb 12 --disk-gb "$PREBUILT_DISK_GB" \
    --user "$PREBUILT_USER" --full-name "$PREBUILT_FULLNAME" --hostname omarchy \
    $(for f in $PREBUILT_FEATURES; do printf -- '--feature %s ' "$f"; done)
}

# app: OmacVM.app's create script with the image's answers, as the app runs
# it, but nothing of this Mac in the VM (OMACVM_CREATE_IMAGE: no Bridge token,
# no Mac helpers). The password is thrown away with the user.
stage_build_app() {
  local port
  [[ -e $APPVM/disk.img ]] && die "$APPVM exists: delete it first (make-image.sh app clean)"
  if [[ -n ${OMACVM_PREBUILT_APP:-} ]]; then
    [[ -x $OMACVM_PREBUILT_APP/Contents/Resources/runtime/bin/OmacVM ]] || die "no QEMU runtime in $OMACVM_PREBUILT_APP"
  else
    [[ -x $R/app/runtime/.build/qemu-gpu-runtime/bin/qemu-system-aarch64 ]] ||
      die "no QEMU runtime in this checkout: app/scripts/build-app.sh builds it"
  fi
  log "build: $VM in $APPVM"
  port=$(app_free_port) || die "no free port for the VM's SSH"
  mkdir -p "$APPVM"
  {
    printf "NAME='%s'\nCPUS=8\nMEM_MB=12288\nDISK_GB=%s\nSSH_PORT=%s\n" "$VM" "$PREBUILT_DISK_GB" "$port"
    printf "VM_USER='%s'\nVM_FULLNAME='%s'\nVM_HOSTNAME=omarchy\n" "$PREBUILT_USER" "$PREBUILT_FULLNAME"
    printf "VM_TZ=UTC\nVM_LANG=en_US.UTF-8\nKEYBOARD=us\nFEATURES='%s'\n" "$PREBUILT_FEATURES"
  } > "$APPVM/vm.env"
  openssl rand -hex 16 | OMACVM_CREATE_IMAGE=1 "$APPSCRIPTS/create-vm.sh" "$APPVM" ||
    die "the build stopped (logs in $APPVM/logs)"
}

stage_generalize() {
  local ip audit
  if [[ $ROUTE == app ]]; then
    running || { log "starting $VM (no window)"; app_boot; }
  else
    running || { log "starting $VM"; vm_boot "$VM" "$ROUTE" >/dev/null; }
  fi
  ip=$(vm_ip_now 300) || die "no address for $VM"
  wait_ssh "$ip" 300
  # Strings that must not be in the image: this Mac's user, name, computer
  # name, e-mail, SSH keys, Bridge token.
  audit=$( {
    id -un; id -F 2>/dev/null; scutil --get ComputerName 2>/dev/null; scutil --get LocalHostName 2>/dev/null
    git config --global user.email 2>/dev/null; git config --global user.name 2>/dev/null
    for k in "$HOME"/.ssh/*.pub; do awk '{ print $2 }' "$k"; done
    cat "$HOME/Library/Application Support/omacvm-bridge/token" 2>/dev/null; echo
  } | awk 'length($0) >= 4' | sort -u | base64)
  [[ -s $OUT/omarchy-version ]] || gssh "$ip" "d=/home/$PREBUILT_USER/.local/share/omarchy; echo \"\$(cat \$d/version) (omarchy-mac \$(git -c safe.directory='*' -C \$d rev-parse --short HEAD))\"" \
    < /dev/null > "$OUT/omarchy-version"
  log "Omarchy $(cat "$OUT/omarchy-version")"
  gssh "$ip" "LC_ALL=C pacman -Qi | awk -F' *: ' '/^Name/ { n = \$2 } /^Version/ { v = \$2 } /^Licenses/ { print n, v, \$2 }'" \
    < /dev/null > "$OUT/packages.txt"
  log "$(wc -l < "$OUT/packages.txt" | tr -d ' ') packages"
  log "generalize $VM at $ip"
  COPYFILE_DISABLE=1 tar --no-xattrs -C "$R/src/prebuilt/guest" -czf - . |
    gssh "$ip" "rm -rf /root/omacvm-prebuilt && mkdir -p /root/omacvm-prebuilt && tar --no-same-owner -C /root/omacvm-prebuilt -xzf -"
  gssh "$ip" "bash /root/omacvm-prebuilt/generalize.sh --user '$PREBUILT_USER' --type '$ROUTE' --audit-b64 '$(tr -d '\n' <<<"$audit")'" < /dev/null
  log "waiting for $VM to power off"
  wait_off
}

stage_package() {
  local b stage name parts omarchy
  running && die "$VM is running: generalize powers it off"
  b=$(bundle); [[ -d $b ]] || die "no bundle at $b"
  rm -rf "$WORK"; mkdir -p "$WORK"
  name=$PREBUILT_NAME
  case $ROUTE in
    parallels)
      stage="$WORK/$name.pvm"; mkdir -p "$stage/omarchy.hdd"
      # OmacVM's disks are plain (a raw file): copy it with the zeroed space
      # left out (holes), which prl_disk_tool cannot compact.
      log "copying the disk without its free space"
      for f in "$b/omarchy.hdd"/*; do
        case $f in
          *.hds) dd if="$f" of="$stage/omarchy.hdd/$(basename "$f")" bs=4m conv=sparse status=none ;;
          *.Backup) ;;
          *) cp "$f" "$stage/omarchy.hdd/" ;;
        esac
      done
      [[ -f $b/NVRAM.dat ]] && cp -c "$b/NVRAM.dat" "$stage/"
      cp "$b/config.pvs" "$stage/config.pvs"
      python3 "$R/src/prebuilt/vmconfig.py" pvs-generalize "$stage/config.pvs" "$name" ;;
    utm)
      stage="$WORK/$name.utm"; mkdir -p "$stage/Data"
      cp "$b/config.plist" "$stage/"
      cp -c "$b"/Data/*.qcow2 "$stage/Data/"
      cp -c "$b"/Data/efi_vars.fd "$stage/Data/" 2>/dev/null || true
      cp -c "$b"/Data/omacvm.png "$stage/Data/" 2>/dev/null || true
      python3 "$R/src/prebuilt/vmconfig.py" utm-generalize "$stage/config.plist" "$name" ;;
    app)
      # The raw disk without its zeroed free space (holes; tar keeps them).
      # No firmware variables: the install makes fresh ones and GRUB boots
      # from the disk's fallback path (\EFI\BOOT\BOOTAA64.EFI).
      log "copying the disk without its free space"
      stage="$WORK/$name"; mkdir -p "$stage"
      dd if="$b/disk.img" of="$stage/disk.img" bs=4m conv=sparse status=none
      sparse_disk "$stage/disk.img" ;;
    fusion)
      log "compacting the disk"
      "$FUSION_LIB/vmware-vdiskmanager" -k "$b/omarchy.vmdk" >/dev/null
      stage="$WORK/$name.vmwarevm"; mkdir -p "$stage"
      cp -c "$b/omarchy.vmdk" "$stage/"
      cp "$b/$VM.vmx" "$stage/$name.vmx"
      [[ -f $b/$VM.nvram ]] && cp -c "$b/$VM.nvram" "$stage/$name.nvram"
      python3 "$R/src/prebuilt/vmconfig.py" vmx-generalize "$stage/$name.vmx" "$name" ;;
  esac
  compress_stage "$stage"
}

# sparse_disk FILE: every zeroed MiB of a raw disk becomes a hole, then a
# check. dd conv=sparse alone once (2026-10-08) left the app's 64 GB disk
# 62 GB allocated: tar packs allocated zeros as data, and every VM made from
# that image took 60 GB on the Mac instead of 7.
sparse_disk() {
  local f=$1 kb
  kb=$(python3 "$R/src/prebuilt/sparsify.py" "$f" | awk '{ print $2 }') || die "could not make $f sparse"
  [[ $kb =~ ^[0-9]+$ ]] || die "could not make $f sparse"
  (( kb < PREBUILT_DISK_GB * 1048576 / 2 )) ||
    die "$f still takes $((kb / 1048576)) GB of its $PREBUILT_DISK_GB GB after making it sparse: is its free space zeroed?"
  log "disk: $((kb / 1024)) MB in use"
}

# compress_stage DIR: the bundle into parts, manifest, sums.
compress_stage() {
  local stage=$1 omarchy
  # Nothing of this Mac in the configuration files.
  if grep -rIl -e "$HOME" -e "$(id -un)" "$stage" --exclude='*.qcow2' --exclude='*.hds' --exclude='*.vmdk' --exclude='*.img' --exclude='*.fd' --exclude='*.dat' --exclude='*.nvram' 2>/dev/null; then
    die "the files above still name this Mac's user"
  fi
  omarchy=$(cat "$OUT/omarchy-version" 2>/dev/null || echo unknown)
  local base=omacvm-prebuilt-$VERSION-$ROUTE
  rm -f "$OUT/$base".tar.zst.* "$OUT/$base.json" "$OUT/$base.json.sig"
  log "compressing (zstd -19, a while)"
  local t0; t0=$(date +%s)
  # Owner root in the archive, not this Mac's user (unpacking gives the files
  # to whoever unpacks them anyway).
  COPYFILE_DISABLE=1 tar --no-xattrs --uid 0 --gid 0 --uname root --gname root -C "$WORK" -cf - "$(basename "$stage")" |
    zstd -19 --long=27 -T8 -q -c | split -b 1900m -a 2 - "$OUT/$base.tar.zst.part-"
  log "compressed in $(( ($(date +%s) - t0) / 60 )) minutes"
  # Signed with OmacVM's release key (the main one from the Keychain, or
  # OMACVM_RELEASE_KEY_FILE) and read back as omacvm build and the app read
  # it; "devid_teams": the Developer ID team of the release app
  # (OMACVM_PREBUILT_APP, else app/dist/OmacVM.app) or of OMACVM_SIGN_ID
  # (src/release/release-key.sh); OMACVM_NEXT_SPARE_KEY / OMACVM_REVOKED_KEYS
  # as for the app's feed.
  local teams app=()
  if [[ -n ${OMACVM_PREBUILT_APP:-} ]]; then app=("$OMACVM_PREBUILT_APP")
  elif [[ -d $R/app/dist/OmacVM.app ]]; then app=("$R/app/dist/OmacVM.app"); fi
  teams=$("$R/src/release/release-key.sh" teams ${app[@]+"${app[@]}"}) || die "no Developer ID team for the manifest"
  python3 "$R/src/prebuilt/manifest.py" write "$OUT/$base.json" --route "$ROUTE" --omacvm "$VERSION" \
    --omarchy "$omarchy" --bundle "$(basename "$stage")" --unpacked "$(du -sk "$stage" | cut -f1)" \
    --disk-gb "$PREBUILT_DISK_GB" --teams "$teams" --next-spare-key "${OMACVM_NEXT_SPARE_KEY:-}" \
    --revoked-keys "${OMACVM_REVOKED_KEYS:-}" "$OUT/$base".tar.zst.part-*
  "$R/src/release/release-key.sh" sign "$OUT/$base.json" || die "the manifest was not signed"
  python3 "$R/src/prebuilt/manifest.py" get "$OUT/$base.json" route >/dev/null || die "the signed manifest does not read back"
  (cd "$OUT" && shasum -a 256 "$base".tar.zst.part-* "$base.json" "$base.json.sig" > "$base.sha256")
  cp "$R/src/prebuilt/SOURCES.md" "$OUT/SOURCES.md"
  cp "$OUT/packages.txt" "$OUT/$base-packages.txt"
  rm -rf "$WORK"
  ls -lh "$OUT"
}

# repack: the parts made before, unpacked, their configuration generalized
# again with this checkout's vmconfig.py, packed again (no VM needed).
stage_repack() {
  local base=omacvm-prebuilt-$VERSION-$ROUTE stage
  ls "$OUT/$base".tar.zst.part-* >/dev/null || die "nothing to repack in $OUT"
  rm -rf "$WORK"; mkdir -p "$WORK"
  cat "$OUT/$base".tar.zst.part-* | zstd -dc --long=27 -q | { tar -xSf - -C "$WORK" && cat > /dev/null; }   # as prebuilt_unpack
  stage=$(ls -d "$WORK"/"$PREBUILT_NAME"*)
  case $ROUTE in
    app) sparse_disk "$stage/disk.img" ;;   # a disk only: nothing to generalize again
    parallels) python3 "$R/src/prebuilt/vmconfig.py" pvs-generalize "$stage/config.pvs" "$PREBUILT_NAME" ;;
    utm) python3 "$R/src/prebuilt/vmconfig.py" utm-generalize "$stage/config.plist" "$PREBUILT_NAME" ;;
    fusion) python3 "$R/src/prebuilt/vmconfig.py" vmx-generalize "$stage/$PREBUILT_NAME.vmx" "$PREBUILT_NAME" ;;
  esac
  compress_stage "$stage"
}

stage_upload() {
  local base=omacvm-prebuilt-$VERSION-$ROUTE
  ls "$OUT/$base".tar.zst.part-* >/dev/null || die "nothing to upload in $OUT"
  if ! gh release view "$TAG" -R "$PREBUILT_REPO" >/dev/null 2>&1; then
    log "creating the pre-release $TAG"
    gh release create "$TAG" -R "$PREBUILT_REPO" --prerelease --target "${OMACVM_PREBUILT_TARGET:-main}" \
      --title "Prebuilt VMs for OmacVM $VERSION ($TAG)" \
      --notes "Prebuilt Omarchy VMs for OmacVM $VERSION. Use them with: omacvm build --prebuilt. What's inside: [SOURCES.md](https://github.com/$PREBUILT_REPO/releases/download/$TAG/SOURCES.md); how they are made: [docs/prebuilt.md](https://github.com/$PREBUILT_REPO/blob/main/docs/prebuilt.md)." >/dev/null
  fi
  log "uploading $base to $TAG"
  [[ -f $OUT/$base.json.sig ]] || die "$base.json has no signature: package again"
  gh release upload "$TAG" -R "$PREBUILT_REPO" --clobber "$OUT/$base".tar.zst.part-* "$OUT/$base.json" "$OUT/$base.json.sig" \
    "$OUT/$base.sha256" "$OUT/$base-packages.txt" "$OUT/SOURCES.md"
}

stage_clean() {
  running && die "$VM is running"
  local b; b=$(bundle)
  case $ROUTE in
    parallels) "$PRLCTL" unregister "$VM" >/dev/null 2>&1 || true; [[ $b == *"/OmacVM Image Parallels.pvm" ]] && rm -rf "$b" ;;
    utm) osascript -e "tell application \"UTM\" to delete virtual machine named \"$VM\"" >/dev/null ;;
    fusion) "$VMRUN" -T fusion deleteVM "$(fusion_vmx "$VM")" >/dev/null 2>&1 || { [[ $b == *"/OmacVM Image Fusion.vmwarevm" ]] && rm -rf "$b"; } ;;
    app) [[ $b == "$OUT/vm" && -f $b/vm.env ]] && rm -rf "$b" ;;
  esac
  log "deleted $VM"
}

for s in "${STAGES[@]}"; do
  case $s in
    build|generalize|package|repack|upload|clean) "stage_$s" ;;
    *) die "unknown stage $s" ;;
  esac
done
