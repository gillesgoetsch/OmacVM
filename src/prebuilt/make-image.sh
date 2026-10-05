#!/bin/bash
# Make a prebuilt OmacVM image for one route, for a GitHub release.
#
#   src/prebuilt/make-image.sh parallels|utm|fusion [STAGE...]
#
# Stages (all of them, in this order, when none is given):
#   build       omacvm build --image: a normal build with a placeholder user and
#               nothing of this Mac (no Bridge token, no Parallels Tools)
#   generalize  in the VM: remove the user, keys, logs and caches, install the
#               first-boot service, check for personal data, zero the free space
#   package     compact the disk, copy the bundle without logs or Mac paths,
#               tar + zstd -19, split into 1.9 GB parts, manifest + SHA-256 sums
#   repack      the packed image again with this checkout's configuration edits
#   upload      to the GitHub release $OMACVM_PREBUILT_TAG (default
#               prebuilt-VERSION), created as a pre-release if missing
#   clean       delete the image VM (only the one this script made)
#
# Output: ~/Library/Caches/omacvm/prebuilt-out/<route>/ (or $OMACVM_PREBUILT_OUT).
# Resources: 8 CPUs, 12 GB memory, a 64 GB disk (grown on install).
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
source "$R/src/lib/mac.sh"
source "$R/src/lib/vm.sh"
source "$R/src/vm/fusion.sh"
source "$R/src/prebuilt/lib.sh"

ROUTE=${1:-}; shift || true
case $ROUTE in parallels|utm|fusion) ;; *) sed -n '2,20s/^# \{0,1\}//p' "$0"; exit 2 ;; esac
STAGES=("$@"); (( ${#STAGES[@]} )) || STAGES=(build generalize package)
VERSION=$(cat "$R/src/VERSION")
case $ROUTE in parallels) VM="OmacVM Image Parallels" ;; utm) VM="OmacVM Image UTM" ;; fusion) VM="OmacVM Image Fusion" ;; esac
OUT=${OMACVM_PREBUILT_OUT:-$HOME/Library/Caches/omacvm/prebuilt-out}/$ROUTE
WORK=$OUT/work
TAG=${OMACVM_PREBUILT_TAG:-prebuilt-$VERSION}
export OMA_KEY=$HOME/.ssh/omacvm
mkdir -p "$OUT"

bundle() {   # the image VM's bundle on this Mac
  case $ROUTE in
    parallels) vm_bundle "$VM" ;;
    utm) echo "$UTM_DOCS/$VM.utm" ;;
    fusion) fusion_bundle "$VM" ;;
  esac
}
vm_ip_now() { vm_find_ip "$VM" "$ROUTE" "${1:-1}"; }
running() { vms_list | awk -F'\t' -v n="$VM" '$1 == n && $3 == "running" { f = 1 } END { exit !f }'; }
wait_off() {
  case $ROUTE in
    parallels) wait_stopped "$VM" ;;
    utm) utm_wait_stopped "$VM" ;;
    fusion) fusion_wait_stopped "$VM" ;;
  esac
}

stage_build() {
  vms_list | cut -f1 | grep -qxF "$VM" && die "'$VM' exists: delete it first (make-image.sh $ROUTE clean)"
  log "build: $VM"
  rm -f "$OUT/omarchy-version" "$OUT/packages.txt"
  OMACVM_PASSWORD=$(openssl rand -hex 16) "$R/omacvm" build --image --vm-type "$ROUTE" --vm-name "$VM" \
    --cpus 8 --memory-gb 12 --disk-gb "$PREBUILT_DISK_GB" \
    --user "$PREBUILT_USER" --full-name "$PREBUILT_FULLNAME" --hostname omarchy \
    $(for f in $PREBUILT_FEATURES; do printf -- '--feature %s ' "$f"; done)
}

stage_generalize() {
  local ip audit
  running || { log "starting $VM"; vm_boot "$VM" "$ROUTE" >/dev/null; }
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

# compress_stage DIR: the bundle into parts, manifest, sums.
compress_stage() {
  local stage=$1 omarchy
  # Nothing of this Mac in the configuration files.
  if grep -rIl -e "$HOME" -e "$(id -un)" "$stage" --exclude='*.qcow2' --exclude='*.hds' --exclude='*.vmdk' --exclude='*.fd' --exclude='*.dat' --exclude='*.nvram' 2>/dev/null; then
    die "the files above still name this Mac's user"
  fi
  omarchy=$(cat "$OUT/omarchy-version" 2>/dev/null || echo unknown)
  local base=omacvm-prebuilt-$VERSION-$ROUTE
  rm -f "$OUT/$base".tar.zst.* "$OUT/$base.json"
  log "compressing (zstd -19, a while)"
  local t0; t0=$(date +%s)
  COPYFILE_DISABLE=1 tar --no-xattrs -C "$WORK" -cf - "$(basename "$stage")" |
    zstd -19 --long=27 -T8 -q -c | split -b 1900m -a 2 - "$OUT/$base.tar.zst.part-"
  log "compressed in $(( ($(date +%s) - t0) / 60 )) minutes"
  python3 "$R/src/prebuilt/manifest.py" write "$OUT/$base.json" --route "$ROUTE" --omacvm "$VERSION" \
    --omarchy "$omarchy" --bundle "$(basename "$stage")" --unpacked "$(du -sk "$stage" | cut -f1)" \
    --disk-gb "$PREBUILT_DISK_GB" "$OUT/$base".tar.zst.part-*
  (cd "$OUT" && shasum -a 256 "$base".tar.zst.part-* "$base.json" > "$base.sha256")
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
  cat "$OUT/$base".tar.zst.part-* | zstd -dc --long=27 -q | tar -xSf - -C "$WORK"
  stage=$(ls -d "$WORK"/"$PREBUILT_NAME".*)
  case $ROUTE in
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
  gh release upload "$TAG" -R "$PREBUILT_REPO" --clobber "$OUT/$base".tar.zst.part-* "$OUT/$base.json" "$OUT/$base.sha256" "$OUT/$base-packages.txt" "$OUT/SOURCES.md"
}

stage_clean() {
  running && die "$VM is running"
  local b; b=$(bundle)
  case $ROUTE in
    parallels) "$PRLCTL" unregister "$VM" >/dev/null 2>&1 || true; [[ $b == *"/OmacVM Image Parallels.pvm" ]] && rm -rf "$b" ;;
    utm) osascript -e "tell application \"UTM\" to delete virtual machine named \"$VM\"" >/dev/null ;;
    fusion) "$VMRUN" -T fusion deleteVM "$(fusion_vmx "$VM")" >/dev/null 2>&1 || { [[ $b == *"/OmacVM Image Fusion.vmwarevm" ]] && rm -rf "$b"; } ;;
  esac
  log "deleted $VM"
}

for s in "${STAGES[@]}"; do
  case $s in
    build|generalize|package|repack|upload|clean) "stage_$s" ;;
    *) die "unknown stage $s" ;;
  esac
done
