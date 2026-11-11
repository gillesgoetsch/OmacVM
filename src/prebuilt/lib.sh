# Prebuilt VMs: shared values and helpers (sourced, Mac side, bash 3.2).

PREBUILT_REPO=gillesgoetsch/omacvm
PREBUILT_USER=omacvmuser            # the placeholder user an image is built with
PREBUILT_FULLNAME="OmacVM User"
PREBUILT_NAME=Omarchy               # the VM's name inside the archive
PREBUILT_DISK_GB=64                 # the image's disk; grown on install
# Features of the image build; omacvm build --prebuilt then applies the chosen ones.
PREBUILT_FEATURES="bridge=on wallpaper=on gestures=on scroll-momentum=off omanotch=off mac-clock=on camera=on battery=off external-brightness=on no-idle-lock=off autologin=off thp-kernel=off"

PREBUILT_CACHE=$HOME/Library/Caches/omacvm/prebuilt
# Kept free on the Mac while a prebuilt VM is set up: the app's own reserve for
# a disk that grows, shrinks or moves (DiskSize.macReserve, 10 GiB).
PREBUILT_MAC_RESERVE_KB=10485760
# The file that marks an unpack folder as OmacVM's (prebuilt_unpack_drop).
PREBUILT_UNPACK_MARK=omacvm-prebuilt-unpack

# prebuilt_lookup TYPE: the newest image for this app with OmacVM's major
# version and a version up to this one (the first omacvm apply brings its
# guest side to this version). Sets PB_TAG, PB_MANIFEST (local file), PB_SIZE
# (bytes), PB_UNPACKED_KB, PB_OMARCHY, PB_VERSION, PB_SOURCE (base URL or folder).
# From 3.4.0 only an image whose signed manifest says Omarchy 4.5 or later
# (manifest.py OMARCHY_FLOOR): an older one is not offered, the VM is built here.
# $OMACVM_PREBUILT_SOURCE: a folder with the files (tests);
# $OMACVM_PREBUILT_TAG: only that release.
prebuilt_lookup() {
  local type=$1 version rel url name iv
  version=$(cat "$R/src/VERSION")
  mkdir -p "$PREBUILT_CACHE/$type"
  PB_VERSION=""
  if [[ -n ${OMACVM_PREBUILT_SOURCE:-} ]]; then
    read -r name iv < <(python3 "$R/src/prebuilt/manifest.py" local "$OMACVM_PREBUILT_SOURCE" "$version" "$type") || return 1
    [[ -n ${name:-} ]] || return 1
    PB_MANIFEST=$PREBUILT_CACHE/$type/$name
    cp "$OMACVM_PREBUILT_SOURCE/$name" "$PB_MANIFEST"
    cp "$OMACVM_PREBUILT_SOURCE/$name.sig" "$PB_MANIFEST.sig" 2>/dev/null || rm -f "$PB_MANIFEST.sig"
    PB_TAG=local; PB_SOURCE=$OMACVM_PREBUILT_SOURCE
  else
    rel=$(mktemp)
    curl -fsSL --max-time 20 -H 'Accept: application/vnd.github+json' \
      "https://api.github.com/repos/$PREBUILT_REPO/releases?per_page=100" -o "$rel" 2>/dev/null || { rm -f "$rel"; return 1; }
    if [[ -n ${OMACVM_PREBUILT_TAG:-} ]]; then
      python3 - "$rel" "$OMACVM_PREBUILT_TAG" > "$rel.one" <<'PY2'
import json, sys
print(json.dumps([r for r in json.load(open(sys.argv[1])) if r.get("tag_name") == sys.argv[2]]))
PY2
      mv "$rel.one" "$rel"
    fi
    read -r PB_TAG url iv < <(python3 "$R/src/prebuilt/manifest.py" release "$rel" "$version" "$type") || true
    rm -f "$rel"
    [[ -n ${url:-} ]] || return 1
    PB_MANIFEST=$PREBUILT_CACHE/$type/${url##*/}
    curl -fsSL --max-time 30 "$url" -o "$PB_MANIFEST" || return 1
    # Its signature (one of OmacVM's release keys): manifest.py checks it
    # before it gives out any value.
    curl -fsSL --max-time 30 "$url.sig" -o "$PB_MANIFEST.sig" || { rm -f "$PB_MANIFEST.sig"; return 1; }
    PB_SOURCE=${url%/*}
  fi
  # manifest.py get checks the signature, then the whole manifest, and fails
  # on anything odd. Each
  # step needs its own "|| return 1": callers use "prebuilt_lookup && ...",
  # where set -e is off.
  local route
  route=$(python3 "$R/src/prebuilt/manifest.py" get "$PB_MANIFEST" route) || return 1
  [[ $route == "$type" ]] || return 1
  PB_VERSION=$(python3 "$R/src/prebuilt/manifest.py" get "$PB_MANIFEST" omacvm) || return 1
  PB_OMARCHY=$(python3 "$R/src/prebuilt/manifest.py" get "$PB_MANIFEST" omarchy) || return 1
  python3 "$R/src/prebuilt/manifest.py" fits "$version" "$PB_OMARCHY" || return 1
  PB_SIZE=$(python3 "$R/src/prebuilt/manifest.py" get "$PB_MANIFEST" size) || return 1
  PB_BUNDLE=$(python3 "$R/src/prebuilt/manifest.py" get "$PB_MANIFEST" bundle) || return 1
  PB_DISK_GB=$(python3 "$R/src/prebuilt/manifest.py" get "$PB_MANIFEST" disk_gb) || return 1
  PB_UNPACKED_KB=$(python3 "$R/src/prebuilt/manifest.py" get "$PB_MANIFEST" unpacked_kb) || return 1
  # And again here, so no manifest text can reach bash arithmetic or a path.
  [[ $PB_SIZE =~ ^[0-9]{1,15}$ && $PB_DISK_GB =~ ^[0-9]{1,4}$ && $PB_UNPACKED_KB =~ ^[0-9]{1,12}$ ]] || return 1
  [[ $PB_BUNDLE =~ ^[A-Za-z0-9._-]{1,64}$ && $PB_BUNDLE != . && $PB_BUNDLE != .. ]] || return 1
  [[ $PB_VERSION =~ ^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}$ ]] || return 1
  [[ $PB_VERSION == "${iv:-$PB_VERSION}" ]]
}

# pb_disk_bigger GB: is GB more than the image's disk? PB_DISK_GB is checked
# to be digits only before it goes near bash arithmetic (a value like
# "a[$(cmd)]" there would run cmd).
pb_disk_bigger() {
  [[ $1 =~ ^[0-9]{1,6}$ && $PB_DISK_GB =~ ^[0-9]{1,4}$ ]] || die "bad disk size in the prebuilt manifest"
  (( 10#$1 > 10#$PB_DISK_GB ))
}

pb_gb() { awk -v b="$1" 'BEGIN { printf "%.1f", b / 1e9 }'; }

# prebuilt_space_ok DEST: room for the parts (in the cache) and the unpacked
# VM (in DEST), and still PREBUILT_MAC_RESERVE_KB free on each volume after
# them. Says what is missing and returns 1 if not.
prebuilt_space_ok() {
  local dest=$1 cache_kb dest_kb need_cache need_dest dl=0 res=$PREBUILT_MAC_RESERVE_KB parts
  mkdir -p "$PREBUILT_CACHE"
  need_cache=$(( 10#$PB_SIZE / 1024 + 1 )); need_dest=$(( 10#$PB_UNPACKED_KB ))
  cache_kb=$(df -Pk "$PREBUILT_CACHE" | awk 'NR == 2 { print $4 }')
  dest_kb=$(df -Pk "$dest" | awk 'NR == 2 { print $4 }')
  [[ $cache_kb =~ ^[0-9]+$ && $dest_kb =~ ^[0-9]+$ ]] || return 0   # df said nothing useful: let it try
  if [[ $(stat -f %d "$PREBUILT_CACHE") == "$(stat -f %d "$dest")" ]]; then
    dl=$need_cache; need_cache=0
  fi
  parts="VM disk $(pb_gb $(( need_dest * 1024 ))) GB"
  (( dl )) && parts="$parts, download $(pb_gb $(( dl * 1024 ))) GB"
  if (( dest_kb < need_dest + dl + res )); then
    echo "Not enough free space on $(pb_volume "$dest"): $(pb_gb $(( (need_dest + dl + res) * 1024 ))) GB needed ($parts, $(pb_gb $(( res * 1024 ))) GB kept free for macOS), $(pb_gb $(( dest_kb * 1024 ))) GB free. Free some space and try again." >&2
    return 1
  fi
  if (( need_cache && cache_kb < need_cache + res )); then
    echo "Not enough free space on $(pb_volume "$PREBUILT_CACHE") for the download: $(pb_gb $(( (need_cache + res) * 1024 ))) GB needed (download $(pb_gb $(( need_cache * 1024 ))) GB, $(pb_gb $(( res * 1024 ))) GB kept free for macOS), $(pb_gb $(( cache_kb * 1024 ))) GB free. Free some space and try again." >&2
    return 1
  fi
}

pb_volume() { df -P "$1" | awk 'NR == 2 { sub(/^([^ ]+ +){5}/, ""); print }'; }

# prebuilt_download: every part into the cache, resumed, checked against the
# manifest's SHA-256. A part that fails its check is fetched again once.
prebuilt_download() {
  local dir name size sum try have
  dir=$(dirname "$PB_MANIFEST")
  while read -r name size sum; do
    [[ $size =~ ^[0-9]{1,15}$ ]] || die "bad part size in the prebuilt manifest"
    for try in 1 2; do
      if [[ -n ${OMACVM_PREBUILT_SOURCE:-} ]]; then
        [[ -f $dir/$name && $(stat -f %z "$dir/$name") == "$size" ]] || cp -c "$PB_SOURCE/$name" "$dir/$name" 2>/dev/null || cp "$PB_SOURCE/$name" "$dir/$name"
      else
        have=$(stat -f %z "$dir/$name" 2>/dev/null || echo 0)
        (( have > size )) && { rm -f "$dir/$name"; have=0; }
        if (( have < size )); then
          curl -fL --retry 5 --retry-delay 3 -C - --progress-bar "$PB_SOURCE/$name" -o "$dir/$name" ||
            curl -fL --retry 5 --retry-delay 3 --progress-bar "$PB_SOURCE/$name" -o "$dir/$name" || true
        fi
      fi
      [[ $(shasum -a 256 "$dir/$name" 2>/dev/null | cut -d' ' -f1) == "$sum" ]] && break
      (( try == 1 )) || die "$name: checksum mismatch (download it again: rm '$dir/$name')"
      info "$name: checksum mismatch, downloading it again"
      rm -f "$dir/$name"
    done
    info "$name: checked ($(pb_gb "$size") GB)"
  done < <(python3 "$R/src/prebuilt/manifest.py" parts "$PB_MANIFEST")
}

# Text from the VM on its way to a terminal: colour codes out, then only
# printable ASCII and tabs (no other escape sequences: a guest could set the
# window title or the Mac's clipboard), lines cut at 240 characters. Line by
# line, so progress still shows as it comes. (OmacVM.app's scripts have the
# same in vm-common.sh.)
printable() {
  LC_ALL=C sed -l -e $'s/\x1b\\[[0-9;]*m//g' -e 's/[^[:print:][:blank:]]//g' -e 's/^\(.\{240\}\).*/\1/'
}

# prebuilt_unpack_drop WORK: WORK goes if it is OmacVM's unpack folder (the
# marker inside). A run that crashed or was killed leaves one behind (53-56 GB
# after the MacBook Air's panic, 2026-11-11), and the next run clears it before
# it checks the free space. Status 1, WORK kept, when it is there without the
# marker: not OmacVM's to delete.
prebuilt_unpack_drop() {
  local u=$1
  [[ -e $u || -L $u ]] || return 0
  [[ -d $u && ! -L $u && -f $u/$PREBUILT_UNPACK_MARK && ! -L $u/$PREBUILT_UNPACK_MARK ]] || return 1
  rm -rf "$u"
}

# prebuilt_unpack_disk WORK DEST: OmacVM.app's image is <bundle>/disk.img and
# nothing else (unpack.py refuses any other entry, a link, a disk of another
# size than the signed manifest's). It goes into WORK (made new, with its
# marker), sparse and bounded, then moves to DEST and WORK goes.
# $ZSTD: OmacVM.app's own zstd (its users need no Homebrew).
#
# Not tar -xS: bsdtar writes the disk's last region (its backup GPT) with one
# write that starts 56 GB past the end of the file, and APFS sometimes fills
# that gap with real zeros: 61 GB on the Mac, which filled a MacBook Air to a
# kernel panic (2026-11-11; 60 of 163 setups since 3.0 took the zeros, #305).
# unpack.py sets the file's size first and writes only inside it; it stops
# when the volume gets below PREBUILT_MAC_RESERVE_KB free, or the file takes
# more than the image's data and 1 GiB. Its message is the one shown. cat reads
# what follows the archive's end marker, or zstd's last write could find the
# pipe closed and fail the unpack (SIGPIPE, with pipefail) now and then.
prebuilt_unpack_disk() {
  local u=$1 f dir err size max msg
  [[ $PB_DISK_GB =~ ^[0-9]{1,4}$ && $PB_UNPACKED_KB =~ ^[0-9]{1,12}$ ]] || die "bad disk size in the prebuilt manifest"
  prebuilt_unpack_drop "$u" || die "$u is in the way and was not made by OmacVM: move it away and try again"
  mkdir "$u" && : > "$u/$PREBUILT_UNPACK_MARK" || die "could not make $u"
  f=$u/disk.img err=$u/unpack.err dir=$(dirname "$PB_MANIFEST")
  size=$(( 10#$PB_DISK_GB * 1073741824 )); max=$(( 10#$PB_UNPACKED_KB * 1024 + 1073741824 ))
  if ! python3 "$R/src/prebuilt/manifest.py" parts "$PB_MANIFEST" | while read -r name _ _; do cat "$dir/$name"; done |
    "${ZSTD:-zstd}" -dc --long=27 -q |
    { python3 -I "$R/src/prebuilt/unpack.py" extract "$PB_BUNDLE/disk.img" "$f" "$size" \
        --max-alloc "$max" --min-free $(( PREBUILT_MAC_RESERVE_KB * 1024 )) 2> "$err" && cat > /dev/null; }; then
    msg=$(tail -n 1 "$err" 2>/dev/null | cut -c1-300)
    prebuilt_unpack_drop "$u" || true
    die "${msg:-could not unpack the image}"
  fi
  [[ -f $f && ! -L $f && $(stat -f %l "$f") == 1 ]] ||
    { prebuilt_unpack_drop "$u" || true; die "the image's disk.img is not a plain file: not used"; }
  mv "$f" "$2"
  prebuilt_unpack_drop "$u" || true
  prebuilt_compact "$2" unpack
}

# prebuilt_compact FILE [unpack]: a raw disk that takes more than half its size on the
# Mac gets every zeroed MiB back as a hole (sparsify.py, bytes unchanged).
# After a setup (#305: a fresh 3.0.9 setup on macOS 15.8.1 ended with 61 GB
# in use, 7.9 after sparsify.py). Right after the unpack it should never find
# any (unpack.py): then it says so as a warning. Only for a disk no VM has
# open: sparsify reads it all (about 10 s for 60 GB) and punches holes where
# it read zeros.
prebuilt_compact() {
  local f=$1 size kb out msg
  size=$(stat -f %z "$f" 2>/dev/null) && kb=$(( $(stat -f %b "$f") / 2 )) || return 0
  (( kb * 1024 > size / 2 )) || return 0
  if out=$(python3 "$R/src/prebuilt/sparsify.py" "$f" 2>/dev/null) && [[ $out =~ ^[0-9]+\ ([0-9]+)$ ]]; then
    msg="disk.img took $((kb / 1048576)) GB of its $((size >> 30)) GB on the Mac: zeros made holes, now $((BASH_REMATCH[1] / 1048576)) GB"
  else
    msg="disk.img takes $((kb / 1048576)) GB of its $((size >> 30)) GB on the Mac; could not make it sparse"
  fi
  if [[ ${2:-} == unpack ]]; then echo "WARN: right after the unpack, $msg"; else info "$msg"; fi
}

prebuilt_cleanup() {   # the downloaded parts (kept with OMACVM_PREBUILT_KEEP=1)
  [[ ${OMACVM_PREBUILT_KEEP:-0} == 1 ]] && return 0
  local dir; dir=$(dirname "$PB_MANIFEST")
  python3 "$R/src/prebuilt/manifest.py" parts "$PB_MANIFEST" | while read -r name _ _; do rm -f "$dir/$name"; done
}

# prebuilt_seed ISO: the answers for the VM's first boot, on a small ISO
# labelled OMACVM-SEED. Needs U FULL HASH HOST KB TZ_MAC LANG_VM TYPE (and
# SEED_NET); the root key is $KEY.pub. The answers hold the
# password hash: only the user can read them, from the first byte (umask), and
# the work folder goes however this ends (a subshell with its own trap).
prebuilt_seed() (
  umask 077
  d=$(mktemp -d) || die "could not make a folder for the seed"
  trap 'rm -rf "$d"' EXIT
  b() { printf '%s' "$1" | base64 | tr -d '\n'; }
  {
    echo "VERSION=$(b 1)"
    echo "USER=$(b "$U")"; echo "FULLNAME=$(b "$FULL")"; echo "HASH=$(b "$HASH")"
    echo "ROOT_KEY=$(b "$(cat "$KEY.pub")")"
    echo "HOSTNAME=$(b "$HOST")"; echo "KEYBOARD=$(b "$KB")"; echo "TIMEZONE=$(b "$TZ_MAC")"
    echo "LANG=$(b "$LANG_VM")"; echo "TYPE=$(b "$TYPE")"
    if [[ -n ${SEED_NET:-} ]]; then echo "NET=$(b "$SEED_NET")"; fi
  } > "$d/seed.env"
  rm -f "$1"
  hdiutil makehybrid -quiet -iso -joliet -default-volume-name OMACVM-SEED -o "$1" "$d" ||
    { rm -f "$1"; die "could not make the seed image"; }
  chmod 600 "$1"
)
