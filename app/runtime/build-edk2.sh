#!/bin/bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: build-edk2.sh --qemu-source DIR --out DIR

Build OmacVM.app's UEFI firmware (edk2-aarch64-code.fd) on the Mac: edk2's
ArmVirtQemu for AARCH64 from the edk2 release QEMU 11.1.1 ships
(edk2-stable202408), built by QEMU's own helper with QEMU's own flags
(DIR/roms/edk2-build.py and DIR/roms/edk2-build.config, build
"armvirt.aa64", a DEBUG build as QEMU ships it). Two patches:
patches/edk2-logo-omarchy.patch, Omarchy's boot logo instead of TianoCore's,
and patches/edk2-bootmanager-nvme-identify-align.patch, so that clang's build
names the VM's disk as QEMU's GCC build does.

DIR is the unpacked QEMU source (build-qemu-gpu-runtime.sh passes its own).
Writes edk2-aarch64-code.fd (64 MiB, as QEMU's) and Logo.bmp (the logo it
carries, for Tests/firmware/test-firmware.py) to the --out DIR.

Toolchain: LLVM 18.1.8 (clang, lld; the official macOS arm64 release),
acpica's iasl 20240827 and edk2's BaseTools, built with the Command Line
Tools. Every download is pinned by checksum and kept in .build/edk2/archives;
a finished build is kept in .build/edk2/out-<inputs> and reused while this
script and the patches stay the same. It builds in /private/tmp/omacvm-edk2-build
(the same folder for every checkout, so they all build the same bytes). About 2 minutes, 800 MB of downloads the
first time.
EOF
}

qemu_source=
out_dir=
while (($#)); do
  case "$1" in
    --qemu-source) (($# >= 2)) || { usage >&2; exit 64; }; qemu_source=$2; shift 2 ;;
    --out) (($# >= 2)) || { usage >&2; exit 64; }; out_dir=$2; shift 2 ;;
    --help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done
[[ -n $qemu_source && -n $out_dir ]] || { usage >&2; exit 64; }

die() { echo "edk2-build: $*" >&2; exit 1; }
log() { echo "[edk2-build] $*"; }

native_dir=$(cd "$(dirname "$0")" && pwd -P)
logo_patch="$native_dir/patches/edk2-logo-omarchy.patch"
logo_patch_sha256=d1763d4db5c616dd8b51d772127555d04d6e68070f8f72f379a69cf496038057
nvme_patch="$native_dir/patches/edk2-bootmanager-nvme-identify-align.patch"
nvme_patch_sha256=f1a494492426f1a1476e96c3682d0d171ef0ca43b386db07ef491e1dd118fda1
# The logo the patch puts in (checked after applying it).
logo_bmp_sha256=75d40490e502d2850e571ab78d4be84b62232279cfc4ec30d23404017f630670

# QEMU's build helper and config at QEMU 11.1.1 (c3d48b7d); roms/edk2-version
# there names edk2-stable202408 of 08/13/2024, and QEMU's prebuilt
# edk2-aarch64-code.fd says "edk2-stable202408-prebuilt.qemu.org".
helper_sha256=88088961d7c26ff85c9a18f2575da70e615ba5e3b97e6db4716119b52524a7db
config_sha256=0346f0e6d2517c8174244a8f9a1fe3d0cbf671c8026bb1c35d9cf2049c4482c2
edk2_version=edk2-stable202408
edk2_date=08/13/2024

# edk2-stable202408 and the submodules ArmVirtQemu needs (its package
# declarations name their include folders), at the commits that tag pins.
edk2_commit=b158dad150bf02879668f72ce306445250838201
# name  commit  repository  path in edk2  sha256 of GitHub's archive
sources() {
  cat <<EOF
edk2	$edk2_commit	tianocore/edk2	.	34005d1062f73d1142ac4ca29b9f456fae99a89f0acc01edf4ff4117d59b7583
openssl	de90e54bbe82e5be4fb9608b6f5c308bb837d355	openssl/openssl	CryptoPkg/Library/OpensslLib/openssl	dbfc74f14091d66b95edab229cff9ef8f1f0ab40da30efec36ca3546a3482b76
mbedtls	8c89224991adff88d53cd380f42a2baa36f91454	ARMmbed/mbedtls	CryptoPkg/Library/MbedTlsLib/mbedtls	b5c7e7c54e013c168f4aae036e59912785f11b4aeebd57f6165a14e879b9a82c
brotli	f4153a09f87cbb9c826d8fc12c74642bb2d879ea	google/brotli	BaseTools/Source/C/BrotliCompress/brotli	6d6cacce05086b7debe75127415ff9c3661849f564fe2f5f3b0383d48aa4ed77
brotli	f4153a09f87cbb9c826d8fc12c74642bb2d879ea	google/brotli	MdeModulePkg/Library/BrotliCustomDecompressLib/brotli	6d6cacce05086b7debe75127415ff9c3661849f564fe2f5f3b0383d48aa4ed77
pylibfdt	cfff805481bdea27f900c32698171286542b8d3c	devicetree-org/pylibfdt	MdePkg/Library/BaseFdtLib/libfdt	1193910f475fde07f3cd4fe1c1a353d69b8cedb574967134838fcdc8208d224e
public-mipi-sys-t	370b5944c046bab043dd8b133727b2135af7747a	MIPI-Alliance/public-mipi-sys-t	MdePkg/Library/MipiSysTLib/mipisyst	9fda3b9a78343ab2be6f06ce6396536e7e065abac29b47c8eb2e42cbb4c4f00b
libspdm	50924a4c8145fc721e17208f55814d2b38766fe6	DMTF/libspdm	SecurityPkg/DeviceSecurity/SpdmLib/libspdm	962aefeeddb130deeb68c6c60c4848ddedd09d7715ed1ba8a8dadabd032d6232
acpica	e80cbd7b52de20aa8c75bfba9845e9cb61f2e681	acpica/acpica	-	bf736d63b94d21995ee8131f0ffcf51c4f42f3f2064d51bedba2952b064f82fe
EOF
}

llvm_root=clang+llvm-18.1.8-arm64-apple-macos11
llvm_archive_name="$llvm_root.tar.xz"
llvm_url="https://github.com/llvm/llvm-project/releases/download/llvmorg-18.1.8/$llvm_archive_name"
llvm_sha256=4573b7f25f46d2a9c8882993f091c52f416c83271db6f5b213c93f0bd0346a10

[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || die "needs macOS on Apple Silicon"
for tool in awk cc curl git install make shasum tar; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool is unavailable: $tool"
done
# edk2-build.py runs BaseTools with /usr/bin/python3 (the Command Line Tools').
[[ -x /usr/bin/python3 ]] && /usr/bin/python3 -c 'import sys; sys.exit(sys.version_info < (3, 8))' ||
  die "/usr/bin/python3 (3.8 or newer) is needed"

sha_of() { shasum -a 256 "$1" | awk '{ print $1 }'; }
check_sha() { [[ $(sha_of "$2") == "$3" ]] || die "$1 checksum mismatch: $2"; }

check_sha "logo patch" "$logo_patch" "$logo_patch_sha256"
check_sha "NVMe identify patch" "$nvme_patch" "$nvme_patch_sha256"
[[ -d $qemu_source/roms && -f $qemu_source/roms/edk2-version ]] || die "not a QEMU source tree: $qemu_source"
check_sha "QEMU's edk2-build.py" "$qemu_source/roms/edk2-build.py" "$helper_sha256"
check_sha "QEMU's edk2-build.config" "$qemu_source/roms/edk2-build.config" "$config_sha256"
grep -qx "EDK2_STABLE = $edk2_version" "$qemu_source/roms/edk2-version" ||
  die "QEMU's roms/edk2-version does not name $edk2_version"

mkdir -p "$out_dir"
cache="$native_dir/.build/edk2"
archives="$cache/archives"
mkdir -p "$archives"
inputs=$(cat "$0" "$logo_patch" "$nvme_patch" | shasum -a 256 | cut -c1-16)
built="$cache/out-$inputs"
if [[ -f $built/edk2-aarch64-code.fd && -f $built/Logo.bmp && -f $built/edk2-aarch64-code.fd.sha256 &&
      $(sha_of "$built/edk2-aarch64-code.fd") == $(cat "$built/edk2-aarch64-code.fd.sha256") ]]; then
  log "Using the firmware built before ($built)"
  install -m 0644 "$built/edk2-aarch64-code.fd" "$built/Logo.bmp" "$out_dir/"
  exit 0
fi

fetch() {   # fetch LABEL URL SHA256 FILE: download once into the archive cache
  local file="$archives/$4"
  if [[ -f $file && $(sha_of "$file") == "$3" ]]; then return; fi
  log "Downloading $1"
  curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
    --retry 3 --retry-all-errors --connect-timeout 20 --output "$file.part" "$2"
  [[ $(sha_of "$file.part") == "$3" ]] || { rm -f "$file.part"; die "$1 checksum mismatch"; }
  mv "$file.part" "$file"
}

# Only the archives below are kept in the cache.
keep=$(sources | cut -f1,2 | tr '\t' '-' | sed 's/$/.tar.gz/'; echo "$llvm_archive_name")
for file in "$archives"/*; do
  [[ -f $file ]] || continue
  grep -qxF "${file##*/}" <<<"$keep" || { log "Removing ${file##*/} (not used)"; rm -f "$file"; }
done

# The build path ends up in the firmware (the DEBUG build's file names, as
# QEMU's carries /home/kraxel/...), so every checkout builds in the same
# folder, outside it and the home folder: the firmware carries no user name,
# and the SEC module's __DATE__ and __TIME__ are the edk2 release's
# (SOURCE_DATE_EPOCH, 2024-08-13 UTC): every checkout builds the same bytes.
# A lock keeps two checkouts from building there at once.
work=/private/tmp/omacvm-edk2-build
lock="$work.lock"
waited=0
until mkdir "$lock" 2>/dev/null; do
  owner=$(cat "$lock/pid" 2>/dev/null || true)
  if [[ -n $owner ]] && ! kill -0 "$owner" 2>/dev/null; then
    rm -rf "$lock"; continue   # its build is gone
  fi
  if [[ -z $owner && -n $(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null) ]]; then
    rm -rf "$lock"; continue   # died before it wrote its pid
  fi
  ((waited % 60)) || log "Waiting for another edk2 build (pid ${owner:-?}, $lock)"
  ((waited < 1200)) || die "another edk2 build has held $lock for 20 minutes"
  sleep 5; waited=$((waited + 5))
done
echo $$ > "$lock/pid"
cleanup() { local s=$?; trap - EXIT; rm -rf "$work" "$lock"; exit "$s"; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
rm -rf "$work" "$built"
mkdir -p "$work"

edk2="$work/edk2"
while IFS=$'\t' read -r name commit repo path sha; do
  fetch "$name $commit" "https://github.com/$repo/archive/$commit.tar.gz" "$sha" "$name-$commit.tar.gz"
  case $path in
    .) dest=$edk2 ;;
    -) dest="$work/$name" ;;
    *) dest="$edk2/$path" ;;
  esac
  mkdir -p "$dest"
  tar -xzf "$archives/$name-$commit.tar.gz" -C "$dest" --strip-components 1
done < <(sources)
fetch "LLVM 18.1.8" "$llvm_url" "$llvm_sha256" "$llvm_archive_name"

log "Unpacking clang and lld"
tar -xJf "$archives/$llvm_archive_name" -C "$work" \
  --include="$llvm_root/bin/clang" --include="$llvm_root/bin/clang-18" \
  --include="$llvm_root/bin/lld" --include="$llvm_root/bin/ld.lld" \
  --include="$llvm_root/bin/llvm-ar" --include="$llvm_root/bin/llvm-objcopy" \
  --include="$llvm_root/lib/clang/18/include/*"
llvm_bin="$work/$llvm_root/bin"
"$llvm_bin/clang" --version | grep -q 'clang version 18.1.8' || die "the unpacked clang does not run"

log "Applying the Omarchy logo and NVMe identify patches"
# git apply checks the original logo's hash; the ceiling keeps git from taking
# the repository around .build for the target. edk2's sources have CRLF lines.
GIT_CEILING_DIRECTORIES=$work git -C "$edk2" apply "$logo_patch"
GIT_CEILING_DIRECTORIES=$work git -C "$edk2" apply --whitespace=nowarn "$nvme_patch"
check_sha "patched logo" "$edk2/MdeModulePkg/Logo/Logo.bmp" "$logo_bmp_sha256"

jobs=${OMARCHY_RUNTIME_BUILD_JOBS:-$(sysctl -n hw.ncpu)}
[[ $jobs =~ ^[1-9][0-9]{0,5}$ ]] || die "OMARCHY_RUNTIME_BUILD_JOBS must be a positive integer"
build_log="$work/build.log"
fail() { tail -n 40 "$build_log" >&2; die "$1 failed (log above)"; }

log "Building iasl (acpica 20240827)"
# Apple's linker refuses acpica's packed pointers (as Homebrew's acpica builds).
make -C "$work/acpica" -j "$jobs" iasl OPT_CFLAGS="-O2 -DACPI_PACKED_POINTERS_NOT_SUPPORTED" \
  >>"$build_log" 2>&1 || fail "iasl"

log "Building edk2's BaseTools"
# Apple's stdint.h defines UINT8_MAX too: a warning, and BaseTools builds with -Werror.
make -C "$edk2/BaseTools" -j "$jobs" EXTRA_OPTFLAGS=-Wno-macro-redefined \
  PYTHON_COMMAND=/usr/bin/python3 >>"$build_log" 2>&1 || fail "BaseTools"

# edk2-build.py pads with GNU truncate (--size); macOS's takes -s.
mkdir -p "$work/bin"
cat > "$work/bin/truncate" <<'EOF'
#!/bin/sh
[ "$1" = --size ] && exec /usr/bin/truncate -s "$2" "$3"
exec /usr/bin/truncate "$@"
EOF
chmod +x "$work/bin/truncate"

log "Building ArmVirtQemu (AARCH64, QEMU's armvirt.aa64 flags, $jobs jobs)"
roms="$work/roms"
mkdir -p "$roms" "$work/pc-bios"
install -m 0644 "$qemu_source/roms/edk2-build.py" "$qemu_source/roms/edk2-build.config" "$roms/"
(
  cd "$roms"
  env -i HOME="$HOME" PATH="$work/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    SOURCE_DATE_EPOCH=1723507200 CLANGDWARF_BIN="$llvm_bin/" CLANG_HOST_BIN=/usr/bin/ IASL_PREFIX="$work/acpica/generate/unix/bin/" \
    /usr/bin/python3 edk2-build.py --config edk2-build.config --core "$edk2" --match armvirt.aa64 \
      --toolchain CLANGDWARF --version-override "$edk2_version-omacvm" --release-date "$edk2_date" \
      --jobs "$jobs"
) >>"$build_log" 2>&1 || fail "the edk2 build"

code="$work/pc-bios/edk2-aarch64-code.fd"
[[ -f $code && $(stat -f %z "$code") == 67108864 ]] || fail "the edk2 build (no 64 MiB edk2-aarch64-code.fd)"
grep -A3 'FV Space Information' "$build_log" | sed 's/^/[edk2-build] /'
# The firmware volumes before compression: no path of this checkout or home.
fv_dir="$roms/Build/ArmVirtQemu-AARCH64/DEBUG_CLANGDWARF/FV"
[[ -f $fv_dir/FVMAIN.Fv && -f $fv_dir/FVMAIN_COMPACT.Fv ]] || die "no firmware volumes in $fv_dir"
for fv in "$fv_dir"/*.Fv; do
  for path in "$native_dir" "$HOME"; do
    ! grep -qaF "$path" "$fv" || die "${fv##*/} carries $path"
  done
done

# Only the latest build is kept.
find "$cache" -maxdepth 1 -name 'out-*' -type d -exec rm -rf {} +
mkdir -p "$built"
install -m 0644 "$code" "$edk2/MdeModulePkg/Logo/Logo.bmp" "$built/"
install -m 0644 "$build_log" "$built/"
sha_of "$built/edk2-aarch64-code.fd" > "$built/edk2-aarch64-code.fd.sha256"
install -m 0644 "$built/edk2-aarch64-code.fd" "$built/Logo.bmp" "$out_dir/"
log "Built $(cat "$built/edk2-aarch64-code.fd.sha256") ($built)"
