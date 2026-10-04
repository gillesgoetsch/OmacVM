#!/usr/bin/env bash
# build-live.sh — OmacVM's temporary live installer.
#
# From vincenzopalazzo/omarchy-parallels (MIT, see LICENSE here), with two
# fixes (work dir created before the key, sparse disk pour). OmacVM only
# uses it to get a bootable ARM64 Linux with SSH into a fresh Parallels VM;
# `omacvm build` then installs Arch Linux ARM + omarchy-mac onto a second disk from
# it and deletes this disk again.
#
# Original description:
#
# Downloads the official try-omarchy release (MIT), repackages its ARM64
# Omarchy rootfs into a GPT disk Parallels' arm64 EFI can boot, scaffolds a
# Parallels VM around it, registers and opens it. No Parallels Pro needed.
#
# See README.md and docs/HOW-IT-WORKS.md. MIT licensed.

set -euo pipefail

# ---------- defaults ----------
VM_NAME="Omarchy ARM"
source "$(dirname "${BASH_SOURCE[0]}")/release.sh"
RELEASE=$LIVE_RELEASE
REPO="omacom/try-omarchy"
# Not OmacVM.app's cache (~/Library/Caches/omacvm/live): this script deletes
# its work files and the DMG when done, the app keeps its unpacked copy.
WORKDIR="${HOME}/Library/Caches/omacvm/build-live"
ESP_SIZE_MIB=1024          # 1 GiB ESP (kernel + initramfs + bootloader)
ROOT_SIZE_GIB=16           # ext4 is grown to this before first boot
VM_DIR="${HOME}/Parallels"
DISK_SIZE_MIB=""           # computed from layout if empty
KEEP_DMGS=0
SKIP_BOOT=0
DMG_PATH=""
RAW_IMAGE=""               # --raw-image PATH: write a plain disk image (UTM) instead of a Parallels VM

log()  { printf '\033[1;32m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
trap 'printf "\033[1;31mbuild-live.sh failed on line %s\033[0m\n" "$LINENO" >&2' ERR

usage() {
  cat <<EOF
usage: build-live.sh [--vm-name NAME] [--vm-dir DIR] [--dmg PATH] [--release TAG]
                     [--root-size-gib N] [--esp-size-mib N] [--disk-size-mib N]
                     [--workdir DIR] [--ssh-key PUBKEY] [--skip-boot] [--keep-dmgs]
                     [--raw-image PATH]
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm-name)        VM_NAME="$2"; shift 2 ;;
    --vm-dir)         PVM_DIR="${2%/}"; shift 2 ;;
    --dmg)            DMG_PATH="$2"; shift 2 ;;
    --release)        RELEASE="$2"; shift 2 ;;
    --root-size-gib)  ROOT_SIZE_GIB="$2"; shift 2 ;;
    --esp-size-mib)   ESP_SIZE_MIB="$2"; shift 2 ;;
    --disk-size-mib)  DISK_SIZE_MIB="$2"; shift 2 ;;
    --workdir)        WORKDIR="$2"; shift 2 ;;
    --skip-boot)      SKIP_BOOT=1; shift ;;
    --keep-dmgs)      KEEP_DMGS=1; shift ;;
    --ssh-key)        SSH_KEY="$2"; shift 2 ;;
    --raw-image)      RAW_IMAGE="$2"; shift 2 ;;
    -h|--help)        usage ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

new_uuid() { python3 -c 'import uuid; print("{%s}" % uuid.uuid4())'; }

# ---------- 0. environment ----------
[[ "$(uname -m)" == "arm64" ]] || die "this builder targets Apple Silicon (arm64); got $(uname -m)"
MACOS_VER="$(sw_vers -productVersion 2>/dev/null || echo 0)"
MACOS_MAJOR="$(printf '%s' "$MACOS_VER" | cut -d. -f1)"
[[ "$MACOS_MAJOR" -ge 14 ]] || die "macOS 14+ required (found $MACOS_VER); Parallels 19+ needs it"
PARALLELS_APP="/Applications/Parallels Desktop.app"
PRLCTL="/usr/local/bin/prlctl"
PRL_DISK_TOOL="/usr/local/bin/prl_disk_tool"
if [[ -z "$RAW_IMAGE" ]]; then
  [[ -d "$PARALLELS_APP" ]] || die "Parallels Desktop not found at $PARALLELS_APP"
  [[ -x "$PRLCTL" ]] || die "prlctl not found — is Parallels Desktop installed?"
  PRL_VER="$("$PRLCTL" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)"
  PRL_MAJOR="$(printf '%s' "$PRL_VER" | cut -d. -f1)"
  [[ "${PRL_MAJOR:-0}" -ge 19 ]] || die "Parallels Desktop 19+ required (found ${PRL_VER:-unknown})"
  info "host: macOS $MACOS_VER, Parallels $PRL_VER"
else
  info "host: macOS $MACOS_VER, writing a raw disk image (UTM)"
fi
FREE_GB="$(df -g "$HOME" 2>/dev/null | tail -1 | awk '{print $4}')"
if [[ -n "$FREE_GB" && "$FREE_GB" -lt 15 ]]; then
  die "need ~15 GB free (found ${FREE_GB} GB)"
fi
if [[ -n "${SSH_KEY:-}" && ! -f "$SSH_KEY" ]]; then
  die "--ssh-key file not found: $SSH_KEY"
fi
if [[ -z "${SSH_KEY:-}" ]]; then
  SSH_KEY="$WORKDIR/omarchy-ssh.pub"
  if [[ ! -f "$SSH_KEY" ]]; then
    log "no --ssh-key given — generating an ephemeral keypair in the workdir"
    mkdir -p "$WORKDIR"
    ssh-keygen -t ed25519 -N "" -C "omacvm-live" -f "${SSH_KEY%.pub}" -q
  else
    info "reusing previously generated key: $SSH_KEY"
  fi
  GENERATED_KEY=1
fi
command -v python3 >/dev/null || die "python3 required"
command -v cpio    >/dev/null || die "cpio required (ships with macOS)"

log "checking/installing build dependencies (brew: zstd, e2fsprogs)"
command -v brew >/dev/null || die "Homebrew is required: https://brew.sh"
brew list zstd >/dev/null 2>&1 || brew install -q zstd >/dev/null
E2FSPROGS="$(brew --prefix e2fsprogs 2>/dev/null || true)"
if [[ -z "$E2FSPROGS" || ! -x "$E2FSPROGS/sbin/debugfs" ]]; then
  brew install -q e2fsprogs >/dev/null
  E2FSPROGS="$(brew --prefix e2fsprogs)"
fi
ZSTD="$(command -v zstd)"
DEBUGFS="$E2FSPROGS/sbin/debugfs"
E2FSCK="$E2FSPROGS/sbin/e2fsck"
RESIZE2FS="$E2FSPROGS/sbin/resize2fs"
DUMPE2FS="$E2FSPROGS/sbin/dumpe2fs"
[[ -x "$DEBUGFS" && -x "$RESIZE2FS" ]] || die "e2fsprogs tools not found under $E2FSPROGS"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

# ---------- 1. fetch + verify try-omarchy artifacts ----------
# The pinned release's DMG must match its pinned SHA-256 (release.sh): a
# download that changed since is refused. Another --release, or your own
# --dmg, is only checked against its own manifest.
DMG="$WORKDIR/TryOmarchy-$RELEASE.dmg"
SRC="${DMG_PATH:-$DMG}"
if [[ ! -f "$SRC" ]]; then
  log "downloading try-omarchy $RELEASE (~1.4 GB)"
  URL="https://github.com/${REPO}/releases/download/${RELEASE}/TryOmarchy.dmg"
  curl -fL --retry 3 -o "$DMG.part" "$URL"   # a broken download is never taken for the DMG
  mv -f "$DMG.part" "$DMG"
  SRC="$DMG"
else
  log "using existing DMG: $SRC"
fi
want=""; [[ $RELEASE == "$LIVE_RELEASE" ]] && want=$LIVE_DMG_SHA256
if [[ -z $DMG_PATH && -n $want ]]; then
  log "checking the DMG against its pinned SHA-256"
  got=$(shasum -a 256 "$SRC" | cut -d' ' -f1)
  [[ $got == "$want" ]] || { rm -f "$DMG"; die "TryOmarchy.dmg $RELEASE is not the pinned one (sha256 $got, expected $want); deleted it, run again to download it again"; }
fi

log "mounting DMG"
MOUNT_OUT="$(hdiutil attach -nobrowse -readonly "$SRC")"
DMG_VOL="$(printf '%s\n' "$MOUNT_OUT" | sed -n 's/.*\(\/Volumes\/.*\)$/\1/p' | head -1)"
[[ -n "$DMG_VOL" ]] || die "could not mount $SRC"
cleanup_dmg() { hdiutil detach "$DMG_VOL" >/dev/null 2>&1 || true; }
trap cleanup_dmg EXIT
APP="$(find "$DMG_VOL" -maxdepth 3 -name '*.app' | head -1)"
[[ -n "$APP" ]] || die "no .app found inside $DMG_VOL"
GUEST_DIR="$APP/Contents/Resources/guest"

log "copying + verifying guest artifacts (SHA256 against bundled manifest)"
cp "$GUEST_DIR/vmlinuz-linux" "$GUEST_DIR/initramfs-linux.img" "$GUEST_DIR/rootfs.ext4.zst" "$WORKDIR/"
python3 - "$DMG_VOL" "$WORKDIR" <<'PY'
import hashlib, json, pathlib, sys
dmg_vol, work = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
apps = list(dmg_vol.glob("*.app")) or list(dmg_vol.glob("*/*.app"))
if not apps:
    sys.exit("ERROR: no .app bundle found in the mounted DMG")
guest = apps[0] / "Contents/Resources/guest"
if not (guest / "guest-manifest.json").exists():
    sys.exit("ERROR: guest-manifest.json not found in the app bundle")
manifest = json.loads((guest / "guest-manifest.json").read_text())
sizes = {a["path"]: a for a in manifest["artifacts"]}
for name in ("vmlinuz-linux", "initramfs-linux.img", "rootfs.ext4.zst"):
    p = work / name
    rec = sizes[name]
    assert p.stat().st_size == rec["bytes"], f"{name}: size mismatch"
    h = hashlib.sha256()
    with p.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 24), b""):
            h.update(chunk)
    assert h.hexdigest() == rec["sha256"], f"{name}: sha256 mismatch"
print("    all artifact hashes verified")
PY

log "decompressing rootfs (6 GiB) — about a minute"
"$ZSTD" -d -f "$WORKDIR/rootfs.ext4.zst" -o "$WORKDIR/rootfs.ext4" 2>/dev/null

log "checking + growing ext4 to ${ROOT_SIZE_GIB} GiB"
"$E2FSCK" -fy "$WORKDIR/rootfs.ext4" >/dev/null 2>&1 || true
ROOT_BYTES=$(( ROOT_SIZE_GIB * 1024 * 1024 * 1024 ))
python3 -c "import sys; open(sys.argv[1],'wb').truncate(int(sys.argv[2]))" \
  "$WORKDIR/rootfs16.ext4" "$ROOT_BYTES"
dd if="$WORKDIR/rootfs.ext4" of="$WORKDIR/rootfs16.ext4" conv=notrunc,sparse bs=4m status=none
"$RESIZE2FS" "$WORKDIR/rootfs16.ext4" "${ROOT_SIZE_GIB}G" | tail -1
FS_UUID="$("$DUMPE2FS" -h "$WORKDIR/rootfs16.ext4" 2>/dev/null | awk -F': *' '/Filesystem UUID/{print $2}')"
[[ "$FS_UUID" =~ ^[0-9a-f-]{36}$ ]] || die "could not read ext4 UUID"
info "ext4 UUID: $FS_UUID"

log "extracting systemd-boot from the guest rootfs"
# debugfs takes its request as one line split at spaces: dump into a temporary
# folder without any (a home folder like "/Volumes/Macintosh SSD/..." has one).
DUMP_TMP=$(mktemp -d)
"$DEBUGFS" -R "dump /usr/lib/systemd/boot/efi/systemd-bootaa64.efi $DUMP_TMP/systemd-bootaa64.efi" \
    "$WORKDIR/rootfs.ext4" >/dev/null 2>&1
mv -f "$DUMP_TMP/systemd-bootaa64.efi" "$WORKDIR/systemd-bootaa64.efi" 2>/dev/null || true
rm -rf "$DUMP_TMP"
file "$WORKDIR/systemd-bootaa64.efi" | grep -q "EFI application" || die "systemd-boot extraction failed"

# ---------- 2. build the ESP ----------
log "building EFI System Partition (${ESP_SIZE_MIB} MiB)"
ESP_DIR="$WORKDIR/esp-root"
rm -rf "$ESP_DIR"; mkdir -p "$ESP_DIR/EFI/BOOT" "$ESP_DIR/EFI/systemd" "$ESP_DIR/loader/entries"
cp "$WORKDIR/vmlinuz-linux" "$ESP_DIR/Image"
log "patching initramfs: inject SSH key ($SSH_KEY) + kmsg stream"
python3 "$SCRIPT_DIR/lib/patch_initramfs.py" \
  "$WORKDIR/initramfs-linux.img" "$ESP_DIR/initramfs-linux.img" \
  10.211.55.2 4499 "$SSH_KEY"
cp "$WORKDIR/systemd-bootaa64.efi" "$ESP_DIR/EFI/BOOT/BOOTAA64.EFI"
cp "$WORKDIR/systemd-bootaa64.efi" "$ESP_DIR/EFI/systemd/systemd-bootaa64.efi"
cat > "$ESP_DIR/loader/loader.conf" <<EOF
timeout 3
default arch
console-mode keep
EOF
cat > "$ESP_DIR/loader/entries/arch.conf" <<EOF
title   Omarchy ARM (Parallels)
linux   /Image
initrd  /initramfs-linux.img
options root=UUID=$FS_UUID rw rootwait console=tty0 loglevel=4 tryomarchy.ssh_access=1 systemd.show_status=false rd.systemd.show_status=false mitigations=off nowatchdog
EOF

ESP_IMG="$WORKDIR/esp.img"
rm -f "$ESP_IMG"
python3 -c "import sys; open(sys.argv[1],'wb').truncate(int(sys.argv[2]))" \
  "$ESP_IMG" "$(( ESP_SIZE_MIB * 1024 * 1024 ))"
ESP_DEV="$(hdiutil attach -nomount -nobrowse "$ESP_IMG" | head -1 | awk '{print $1}')"
if ! diskutil info "$ESP_DEV" 2>/dev/null | grep -q "Disk Image"; then
  hdiutil detach "$ESP_DEV" >/dev/null 2>&1 || true
  die "ESP raw attach sanity check failed"
fi
newfs_msdos -F 32 -v OMARCHYEFI "$ESP_DEV" >/dev/null
hdiutil detach "$ESP_DEV" >/dev/null
ESP_MOUNT="$(hdiutil attach -nobrowse "$ESP_IMG" | sed -n 's/.*\(\/Volumes\/.*\)$/\1/p')"
[[ -n "$ESP_MOUNT" ]] || die "could not mount the freshly formatted ESP"
COPYFILE_DISABLE=1 ditto "$ESP_DIR/" "$ESP_MOUNT"/
hdiutil detach "$ESP_MOUNT" >/dev/null

# ---------- 3. layout + Parallels plain disk ----------
ESP_SECTORS=$(( ESP_SIZE_MIB * 2048 ))                 # 1 MiB = 2048 sectors
ESP_START=2048
ROOT_START=$(( ESP_START + ESP_SECTORS ))
ROOT_SECTORS=$(( ROOT_SIZE_GIB * 1024 * 1024 * 1024 / 512 ))
LAYOUT_END_BYTES=$(( (ROOT_START + ROOT_SECTORS) * 512 ))
if [[ -z "$DISK_SIZE_MIB" ]]; then
  DISK_SIZE_MIB=$(( (LAYOUT_END_BYTES + 1048575) / 1048576 + 128 ))   # layout + 128 MiB slack
fi
TOTAL_LBAS=$(( DISK_SIZE_MIB * 2048 ))

PVM="${PVM_DIR:-$VM_DIR}/$VM_NAME.pvm"   # --vm-dir; VM_DIR stays where other VMs lend VM.app/NVRAM
DISK_NAME="${VM_NAME// /}-0.hdd"
HDD="$PVM/$DISK_NAME"
HDS="$HDD/$DISK_NAME.0.{5fbaabe3-6958-40ff-92a7-860e329aab41}.hds"

if [[ -n "$RAW_IMAGE" ]]; then
  HDS="$RAW_IMAGE"
  log "creating a raw disk image (${DISK_SIZE_MIB} MiB, sparse): $HDS"
  mkdir -p "$(dirname "$HDS")"; rm -f "$HDS"
  python3 -c 'import sys; open(sys.argv[1], "wb").truncate(int(sys.argv[2]) * 1048576)' "$HDS" "$DISK_SIZE_MIB"
else
  [[ -e "$PVM" ]] && die "$PVM already exists — remove it or pick another --vm-name"
  log "creating Parallels plain disk (${DISK_SIZE_MIB} MiB, sparse)"
  mkdir -p "$PVM"
  "$PRL_DISK_TOOL" create --hdd "$HDD" --size "$DISK_SIZE_MIB" --alloc-policy sparse >/dev/null
  [[ -f "$HDS" ]] || die "prl_disk_tool did not produce the expected .hds"
fi

log "pouring GPT + partitions into the disk"
python3 - "$SCRIPT_DIR" "$HDS" "$TOTAL_LBAS" "$ESP_START" "$ESP_SECTORS" \
  "$ROOT_START" "$ROOT_SECTORS" "$WORKDIR" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/lib")
from gptbuild import build_layout, verify, SECT

hds          = sys.argv[2]
total        = int(sys.argv[3])
esp_start    = int(sys.argv[4])
esp_sectors  = int(sys.argv[5])
root_start   = int(sys.argv[6])
root_sectors = int(sys.argv[7])
work         = sys.argv[8]

mbr, hdr, entries, bhdr, bentries = build_layout(
    esp_start, esp_sectors, root_start, root_sectors, total)

with open(hds, "r+b") as f:
    f.seek(0); f.write(mbr)
    f.seek(SECT); f.write(hdr)
    f.seek(2 * SECT); f.write(entries)
    f.seek((total - 33) * SECT); f.write(bentries)
    f.seek((total - 1) * SECT); f.write(bhdr)
    with open(f"{work}/esp.img", "rb") as esp:
        f.seek(esp_start * SECT)
        left = esp_sectors * SECT
        while left:
            b = esp.read(1 << 24)
            if not b:
                break
            f.write(b)
            left -= len(b)
    with open(f"{work}/rootfs16.ext4", "rb") as rt:
        f.seek(root_start * SECT)
        left = root_sectors * SECT
        while left:
            b = rt.read(1 << 24)
            if not b:
                break
            # keep the .hds sparse: holes in the grown ext4 stay holes
            if b.count(0) == len(b):
                f.seek(len(b), 1)
            else:
                f.write(b)
            left -= len(b)

assert verify(hds, esp_start, root_start), "post-pour verification failed"
print("    GPT + ESP + ext4 verified in place")
PY

if [[ -n "$RAW_IMAGE" ]]; then
  rm -f "$WORKDIR/rootfs.ext4" "$WORKDIR/rootfs16.ext4" "$WORKDIR/esp.img" "$WORKDIR/rootfs.ext4.zst"
  rm -rf "$WORKDIR/esp-root"
  if [[ "$KEEP_DMGS" != "1" ]]; then rm -f "$WORKDIR/TryOmarchy-$RELEASE.dmg"; fi
  cleanup_dmg
  trap - EXIT
  log "live installer image ready: $RAW_IMAGE"
  exit 0
fi

# ---------- 4. scaffold the VM bundle ----------
log "scaffolding the VM bundle"
VM_UUID="$(new_uuid)"
DISK_UUID="$(new_uuid)"
rand_mac() { python3 -c 'import random; print("001C42%02X%02X%02X" % (random.randrange(256), random.randrange(256), random.randrange(256)))'; }
GUEST_MAC="$(rand_mac)"
HOST_MAC="$(rand_mac)"
SIZE_ON_DISK_MB="$(du -m "$HDS" | awk '{print $1}')"
# VM.app stub: reuse Parallels' own from an existing VM when available;
# otherwise omit it (Parallels recreates it on first launch/register).
# We never redistribute Parallels files.
EXISTING_APP="$(find "$VM_DIR" -maxdepth 3 -type d -name VM.app 2>/dev/null | head -1 || true)"
if [[ -n "${EXISTING_APP:-}" ]]; then
  cp -R "$EXISTING_APP" "$PVM/VM.app"
else
  info "no existing VM.app found — omitting (Parallels recreates it)"
fi
python3 - "$SCRIPT_DIR/templates/config.pvs.tmpl" "$PVM/config.pvs" \
  "$VM_NAME" "$VM_UUID" "$DISK_UUID" "$DISK_NAME" "$DISK_SIZE_MIB" "$SIZE_ON_DISK_MB" \
  "$GUEST_MAC" "$HOST_MAC" <<'PY'
import sys
tmpl, out, name, vmu, disku, diskname, sizemb, sodmb, gmac, hmac = sys.argv[1:11]
s = (open(tmpl).read()
     .replace("__VM_NAME__", name)
     .replace("__VM_UUID__", vmu)
     .replace("__DISK_UUID__", disku)
     .replace("__DISK_NAME__", diskname)
     .replace("__DISK_SIZE_MB__", sizemb)
     .replace("__DISK_SIZE_ON_DISK_MB__", sodmb)
     .replace("__GUEST_MAC__", gmac)
     .replace("__HOST_MAC__", hmac))
open(out, "w").write(s)
open(out.replace("config.pvs", "config.pvs.backup"), "w").write(s)
PY
NVRAM_SRC="$(find "$VM_DIR" -maxdepth 2 -name NVRAM.dat 2>/dev/null | head -1 || true)"
if [[ -n "${NVRAM_SRC:-}" ]]; then
  cp "$NVRAM_SRC" "$PVM/NVRAM.dat"
else
  info "no existing NVRAM.dat found — omitting (Parallels generates it)"
fi
cp "$SCRIPT_DIR/templates/VmInfo.pvi.tmpl" "$PVM/VmInfo.pvi"

# ---------- 5. register (with ghost-identity retry) ----------
log "registering the VM with Parallels"
REGISTERED=0
for attempt in 1 2 3; do
  if "$PRLCTL" register "$PVM" >/dev/null 2>&1; then
    REGISTERED=1
    break
  fi
  info "register attempt $attempt failed (stale UUID/name) — regenerating VM identity"
  NEW_VMU="$(new_uuid)"
  python3 - "$PVM/config.pvs" "$NEW_VMU" <<'PY'
import re, sys
p, newu = sys.argv[1], sys.argv[2]
s = open(p).read()
s = re.sub(r"<VmUuid>\{[^}]+\}</VmUuid>", f"<VmUuid>{newu}</VmUuid>", s, count=1)
s = re.sub(r"<SourceVmUuid>\{[^}]+\}</SourceVmUuid>", f"<SourceVmUuid>{newu}</SourceVmUuid>", s, count=1)
open(p, "w").write(s)
open(p.replace("config.pvs", "config.pvs.backup"), "w").write(s)
PY
done
[[ "$REGISTERED" == "1" ]] || die "could not register the VM — see docs/HOW-IT-WORKS.md troubleshooting"

# ---------- 6. cleanup + launch ----------
rm -f "$WORKDIR/rootfs.ext4" "$WORKDIR/rootfs16.ext4" "$WORKDIR/esp.img" \
      "$WORKDIR/rootfs.ext4.zst"
rm -rf "$WORKDIR/esp-root"
if [[ "$KEEP_DMGS" != "1" ]]; then rm -f "$WORKDIR/TryOmarchy-$RELEASE.dmg"; fi
cleanup_dmg
trap - EXIT

log "live installer VM '$VM_NAME' registered ($HDS)"

if [[ "$SKIP_BOOT" != "1" ]]; then
  open -a "$PARALLELS_APP" "$PVM"
fi
